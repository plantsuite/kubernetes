#!/usr/bin/env bash
# tools/lib/k8s-adapter.sh
# Adapter da execução real (kubectl/helm/waits/secrets).

# shellcheck source=metrics-server-tls-fix.sh
source "$(dirname "${BASH_SOURCE[0]}")/metrics-server-tls-fix.sh"
# shellcheck source=k8s-wait.sh
source "$(dirname "${BASH_SOURCE[0]}")/k8s-wait.sh"
# shellcheck source=secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"

# No fluxo TUI não usamos prompts interativos de timeout nas funções wait_*.
# Falhas de readiness devem retornar erro para o usuário decidir (retry/cancel).
K8S_WAIT_INTERACTIVE=0

REAL_LAST_ERROR=""
REAL_LAST_DETAIL=""
REAL_STATUS_HOOK=""

real_set_status_detail() {
  local msg="$1"
  REAL_LAST_DETAIL="$msg"
  if [[ -n "$REAL_STATUS_HOOK" ]] && [[ "$(type -t "$REAL_STATUS_HOOK" 2>/dev/null || true)" == "function" ]]; then
    "$REAL_STATUS_HOOK" "$msg"
  fi
}

# Retorna o evento de Warning mais recente de um namespace (opcionalmente filtrado por nome de recurso).
# Útil para exibir contexto quando um rollout atinge o timeout.
get_last_warning_event() {
  local namespace="$1"
  local resource_name="${2:-}"
  local event_msg=""

  # Tenta primeiro eventos do recurso específico
  if [[ -n "$resource_name" ]]; then
    event_msg=$(kubectl get events -n "$namespace" \
      --field-selector "type=Warning,involvedObject.name=${resource_name}" \
      --sort-by='.lastTimestamp' \
      -o jsonpath='{range .items[*]}{.reason}{": "}{.message}{"\n"}{end}' \
      2>/dev/null | grep -v '^$' | tail -1 || true)
  fi

  # Fallback: qualquer Warning no namespace
  if [[ -z "$event_msg" ]]; then
    event_msg=$(kubectl get events -n "$namespace" \
      --field-selector type=Warning \
      --sort-by='.lastTimestamp' \
      -o jsonpath='{range .items[*]}{.reason}{": "}{.message}{"\n"}{end}' \
      2>/dev/null | grep -v '^$' | tail -1 || true)
  fi

  printf '%s' "$event_msg"
}

real_assert_prereqs() {
  if ! command -v kubectl >/dev/null 2>&1; then
    REAL_LAST_ERROR="kubectl não encontrado"
    return 1
  fi
  if ! command -v helm >/dev/null 2>&1; then
    REAL_LAST_ERROR="helm não encontrado"
    return 1
  fi
  return 0
}

real_get_component_path() {
  local base_path="$1"

  if [[ -n "${SELECTED_OVERLAY:-}" && "${SELECTED_OVERLAY:-}" != "base" ]]; then
    local relative_path="${base_path#k8s/base/}"
    # Remove trailing slashes from relative_path before building overlay_path
    relative_path="${relative_path%/}"
    local overlay_path="k8s/overlays/${SELECTED_OVERLAY}/${relative_path}"

    if [[ -d "$overlay_path" ]] && [[ -f "${overlay_path}/kustomization.yaml" || -f "${overlay_path}/kustomization.yml" || -f "${overlay_path}/Kustomization" ]]; then
      echo "$overlay_path"
      return 0
    fi
  fi

  echo "$base_path"
}

real_apply_kustomize_path() {
  local component_path="$1"
  local name="$2"
  local max_retries=3
  local retry_delay=10
  local attempt=1

  while true; do
    real_set_status_detail "Aplicando ${name} (tentativa ${attempt}/${max_retries})..."
    local error_output
    local exit_code
    error_output=$(kubectl kustomize --enable-helm "$component_path" 2>&1 | kubectl apply --server-side --force-conflicts -f - 2>&1)
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      real_set_status_detail "$name aplicado com sucesso"
      return 0
    fi

    if echo "$error_output" | grep -q "error: accumulating resources:"; then
      REAL_LAST_ERROR="Erro de configuração do kustomize em $name"
      REAL_LAST_DETAIL="$error_output"
      return 20
    fi

    if echo "$error_output" | grep -q "error validating"; then
      REAL_LAST_ERROR="Erro de validação de schema em $name"
      REAL_LAST_DETAIL="$error_output"
      return 20
    fi

    if echo "$error_output" | grep -qi " is invalid"; then
      REAL_LAST_ERROR="Objeto inválido em $name"
      REAL_LAST_DETAIL="$error_output"
      return 20
    fi

    if [[ $attempt -lt $max_retries ]]; then
      real_set_status_detail "Falha transitória em $name. Retry automático em ${retry_delay}s (tentativa $((attempt+1))/${max_retries})..."
      sleep "$retry_delay"
      attempt=$((attempt + 1))
      continue
    fi

    REAL_LAST_ERROR="Falha ao aplicar $name após $max_retries tentativas"
    REAL_LAST_DETAIL="$error_output"
    return 30
  done
}

real_apply_component() {
  local base_path="$1"
  local name="$2"
  local component_path
  component_path=$(real_get_component_path "$base_path")
  real_apply_kustomize_path "$component_path" "$name"
}

real_wait_rollouts_from_path() {
  local component_path="$1"
  local namespace="$2"
  local display_name="$3"
  local timeout_secs="${4:-300s}"

  local resources
  resources=$(kubectl kustomize --enable-helm "$component_path" 2>/dev/null \
    | kubectl apply --dry-run=client -o name -f - 2>/dev/null \
    | grep -E '^(deployment.apps|statefulset.apps)/' || true)

  # Componentes sem workload (apenas config/secrets/rbac) não precisam esperar rollout.
  [[ -z "$resources" ]] && return 0

  local resource kind name
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    kind="${resource%%/*}"
    name="${resource#*/}"

    case "$kind" in
      deployment.apps)
        real_set_status_detail "Aguardando deployment ${name} (${display_name})..."
        if ! kubectl -n "$namespace" rollout status "deployment/${name}" --timeout="$timeout_secs" >/dev/null 2>&1; then
          REAL_LAST_ERROR="Timeout aguardando deployment/${name} em ${namespace} — pods não ficaram prontos em ${timeout_secs}s. Verifique: kubectl get pods -n ${namespace}"
          local _evt
          _evt=$(get_last_warning_event "$namespace" "$name" || true)
          if [[ -n "$_evt" ]]; then
            REAL_LAST_DETAIL="Evento k8s: $_evt"
            real_set_status_detail "Evento k8s: $_evt"
          fi
          return 50
        fi
        ;;
      statefulset.apps)
        real_set_status_detail "Aguardando statefulset ${name} (${display_name})..."
        if ! kubectl -n "$namespace" rollout status "statefulset/${name}" --timeout="$timeout_secs" >/dev/null 2>&1; then
          REAL_LAST_ERROR="Timeout aguardando statefulset/${name} em ${namespace} — pods não ficaram prontos em ${timeout_secs}s. Verifique: kubectl get pods -n ${namespace}"
          local _evt
          _evt=$(get_last_warning_event "$namespace" "$name" || true)
          if [[ -n "$_evt" ]]; then
            REAL_LAST_DETAIL="Evento k8s: $_evt"
            real_set_status_detail "Evento k8s: $_evt"
          fi
          return 50
        fi
        ;;
    esac
  done <<< "$resources"

  return 0
}

real_snapshot_workload_generations() {
  local component_path="$1"
  local namespace="$2"

  local resources
  resources=$(kubectl kustomize --enable-helm "$component_path" 2>/dev/null \
    | kubectl apply --dry-run=client -o name -f - 2>/dev/null \
    | grep -E '^(deployment.apps|statefulset.apps)/' || true)

  [[ -z "$resources" ]] && return 0

  local resource kind name gen
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    kind="${resource%%/*}"
    name="${resource#*/}"

    case "$kind" in
      deployment.apps)
        gen=$(kubectl -n "$namespace" get deployment "$name" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
        ;;
      statefulset.apps)
        gen=$(kubectl -n "$namespace" get statefulset "$name" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
        ;;
    esac

    if [[ -n "$gen" ]]; then
      echo "${resource}:${gen}"
    fi
  done <<< "$resources"
}

real_workload_generation_changed() {
  local snapshot="$1"
  local namespace="$2"

  local resource="${snapshot%%:*}"
  local old_gen="${snapshot##*:}"
  local kind="${resource%%/*}"
  local name="${resource#*/}"

  local new_gen=""
  case "$kind" in
    deployment.apps)
      new_gen=$(kubectl -n "$namespace" get deployment "$name" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
      ;;
    statefulset.apps)
      new_gen=$(kubectl -n "$namespace" get statefulset "$name" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
      ;;
  esac

  [[ -z "$new_gen" ]] && return 1
  [[ "$new_gen" != "$old_gen" ]] && return 0
  return 1
}

real_ensure_restart_after_apply() {
  local component_path="$1"
  local namespace="$2"
  local display_name="$3"
  local snapshot="$4"
  local timeout_secs="${5:-300s}"
  local skip_restart="${6:-false}"

  [[ "$skip_restart" == "true" ]] && return 0
  [[ -z "$snapshot" ]] && return 0

  local line resource kind name
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    resource="${line%%:*}"
    kind="${resource%%/*}"
    name="${resource#*/}"

    if real_workload_generation_changed "$line" "$namespace"; then
      real_set_status_detail "Generation alterado em ${kind}/${name} — aguardando rollout (${display_name})..."
    else
      real_set_status_detail "Forçando restart do ${kind} ${name} (${display_name})..."
      if ! kubectl -n "$namespace" rollout restart "$resource" 2>/dev/null; then
        REAL_LAST_ERROR="Falha ao forçar restart de ${resource} em ${namespace}"
        return 51
      fi
    fi

    if ! kubectl -n "$namespace" rollout status "$resource" --timeout="$timeout_secs" >/dev/null 2>&1; then
      REAL_LAST_ERROR="Timeout aguardando rollout de ${resource} em ${namespace} — pods não ficaram prontos em ${timeout_secs}s. Verifique: kubectl get pods -n ${namespace}"
      local _evt
      _evt=$(get_last_warning_event "$namespace" "$name" || true)
      if [[ -n "$_evt" ]]; then
        REAL_LAST_DETAIL="Evento k8s: $_evt"
        real_set_status_detail "Evento k8s: $_evt"
      fi
      return 50
    fi
  done <<< "$snapshot"

  return 0
}

real_apply_and_ensure_restart() {
  local component_path="$1"
  local name="$2"
  local namespace="$3"
  local timeout_secs="${4:-300s}"
  local skip_restart="${5:-false}"

  local snapshot
  snapshot=$(real_snapshot_workload_generations "$component_path" "$namespace")

  real_apply_kustomize_path "$component_path" "$name" || return $?

  real_ensure_restart_after_apply "$component_path" "$namespace" "$name" "$snapshot" "$timeout_secs" "$skip_restart" || return $?

  return 0
}

real_apply_plantsuite_service() {
  local svc="$1"

  if [[ -z "$svc" ]]; then
    REAL_LAST_ERROR="Serviço PlantSuite não informado"
    return 40
  fi

  local svc_base="k8s/base/plantsuite/$svc/"
  if [[ ! -d "$svc_base" ]]; then
    REAL_LAST_ERROR="Serviço PlantSuite desconhecido: $svc"
    return 40
  fi

  local component_path
  component_path=$(real_get_component_path "$svc_base")

  if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
    real_apply_and_ensure_restart "$component_path" "plantsuite/$svc" "plantsuite" "300s" || return $?
  else
    real_apply_kustomize_path "$component_path" "plantsuite/$svc" || return $?
    real_wait_rollouts_from_path "$component_path" "plantsuite" "plantsuite/$svc" || return $?
  fi
  return 0
}

real_delete_plantsuite_service() {
  local svc="$1"

  if [[ -z "$svc" ]]; then
    REAL_LAST_ERROR="Servico PlantSuite nao informado para remocao"
    return 40
  fi

  case "$svc" in
    portal|tenants)
      REAL_LAST_ERROR="Remocao bloqueada para servico protegido: $svc"
      return 41
      ;;
  esac

  local svc_base="k8s/base/plantsuite/$svc/"
  if [[ ! -d "$svc_base" ]]; then
    REAL_LAST_ERROR="Servico PlantSuite desconhecido para remocao: $svc"
    return 40
  fi

  local component_path
  component_path=$(real_get_component_path "$svc_base")

  real_set_status_detail "Removendo plantsuite/$svc..."
  klog "Removendo plantsuite/$svc..."

  local output
  output=$(kubectl kustomize --enable-helm "$component_path" 2>&1 | kubectl delete -f - --ignore-not-found=true 2>&1)
  if [[ $? -ne 0 ]]; then
    REAL_LAST_ERROR="Falha ao remover plantsuite/$svc"
    REAL_LAST_DETAIL="$output"
    klog "Erro ao remover plantsuite/$svc"
    return 30
  fi

  real_set_status_detail "plantsuite/$svc removido"
  klog "plantsuite/$svc removido com sucesso"
  return 0
}

real_wait_namespace_deleted() {
  local namespace="$1"
  local timeout=120
  local elapsed=0
  local interval=2
  local spinner=("|" "/" "-" "\\")

  if ! kubectl get namespace "$namespace" &>/dev/null; then
    klog "Namespace $namespace não existe ou já foi removido."
    return 0
  fi

  while [[ $elapsed -lt $timeout ]]; do
    if ! kubectl get namespace "$namespace" &>/dev/null; then
      printf "\r\033[K"
      klog "Namespace $namespace foi removido."
      return 0
    fi
    idx=$(( (elapsed / interval) % 4 ))
    printf "\rAguardando namespace %s ser removido... %s" "$namespace" "${spinner[$idx]}"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  printf "\r\033[K"
  warning "Namespace $namespace não foi removido no tempo esperado. Continuando..."
  return 0
}

real_wait_statefulset_deleted() {
  local namespace="$1"
  local selector="$2"
  local name="$3"
  local timeout=120
  local elapsed=0
  local interval=2
  local spinner=("|" "/" "-" "\\")

  local sts_name
  sts_name=$(kubectl get sts -n "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$sts_name" ]]; then
    sts_name="$name"
  fi

  if ! kubectl get sts "$sts_name" -n "$namespace" &>/dev/null; then
    klog "StatefulSet $sts_name não existe ou já foi removido."
    return 0
  fi

  while [[ $elapsed -lt $timeout ]]; do
    if ! kubectl get sts "$sts_name" -n "$namespace" &>/dev/null; then
      printf "\r\033[K"
      klog "StatefulSet $sts_name removido."
      return 0
    fi
    idx=$(( (elapsed / interval) % 4 ))
    printf "\rAguardando StatefulSet %s ser removido... %s" "$sts_name" "${spinner[$idx]}"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  printf "\r\033[K"
  warning "StatefulSet $sts_name não foi removido no tempo esperado. Continuando..."
  return 0
}

real_wait_cr_deleted() {
  local kind="$1"
  local name="$2"
  local namespace="$3"
  local timeout=120
  local elapsed=0
  local interval=2
  local spinner=("|" "/" "-" "\\")

  if ! kubectl get "$kind" "$name" -n "$namespace" &>/dev/null; then
    klog "$kind $name não existe ou já foi removido."
    return 0
  fi

  while [[ $elapsed -lt $timeout ]]; do
    if ! kubectl get "$kind" "$name" -n "$namespace" &>/dev/null; then
      printf "\r\033[K"
      klog "$kind $name removido."
      return 0
    fi
    idx=$(( (elapsed / interval) % 4 ))
    printf "\rAguardando %s %s ser removido... %s" "$kind" "$name" "${spinner[$idx]}"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  printf "\r\033[K"
  warning "$kind $name não foi removido no tempo esperado. Continuando..."
  return 0
}

real_remove_cr_finalizers() {
  local kind="$1"
  local name="$2"
  local namespace="$3"

  local finalizers
  finalizers=$(kubectl get "$kind" "$name" -n "$namespace" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)

  if [[ -z "$finalizers" ]]; then
    klog "$kind $name não tem finalizers ou já foi removido."
    return 0
  fi

  klog "Removendo finalizers de $kind $name (operador pode estar com problemas)..."
  kubectl patch "$kind" "$name" -n "$namespace" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>&1 || {
    warning "Falha ao remover finalizers de $kind $name"
    return 1
  }

  klog "Finalizers removidos de $kind $name."
  return 0
}

real_delete_cr_with_finalizer_handling() {
  local kind="$1"
  local name="$2"
  local namespace="$3"

  real_set_status_detail "Removendo $kind $name..."
  klog "Removendo $kind $name"

  local output
  output=$(kubectl delete "$kind" "$name" -n "$namespace" --ignore-not-found=true 2>&1)
  local delete_exit=$?

  if [[ $delete_exit -eq 0 ]] || echo "$output" | grep -q "NotFound"; then
    klog "$kind $name deletado com sucesso."
    return 0
  fi

  warning " Deleção de $kind $name pode ter ficado presa. Aguardando..."
  real_wait_cr_deleted "$kind" "$name" "$namespace"
  local wait_result=$?

  if [[ $wait_result -eq 0 ]]; then
    return 0
  fi

  if kubectl get "$kind" "$name" -n "$namespace" &>/dev/null; then
    real_remove_cr_finalizers "$kind" "$name" "$namespace"
    sleep 2
    kubectl delete "$kind" "$name" -n "$namespace" --ignore-not-found=true 2>&1
  fi

  return 0
}

real_delete_infra_component() {
  local base_path="$1"
  local name="$2"

  local component_path
  component_path=$(real_get_component_path "$base_path")

  real_set_status_detail "Removendo $name..."
  klog "Removendo $name (path: $component_path)"

  local output
  output=$(kubectl kustomize --enable-helm "$component_path" 2>&1 | kubectl delete -f - --ignore-not-found=true 2>&1)
  if [[ $? -ne 0 ]]; then
    warning "Falha ao remover $name. Continuando..."
    echo "$output" >&2
  else
    klog "$name removido com sucesso."
  fi

  return 0
}

real_delete_plantsuite_all() {
  real_set_status_detail "Removendo todos os serviços plantsuite..."
  klog "Removendo todos os serviços plantsuite"

  kubectl get namespace plantsuite &>/dev/null || {
    klog "Namespace plantsuite não existe."
    return 0
  }

  local output
  output=$(kubectl kustomize --enable-helm "k8s/base/plantsuite/" 2>&1 | kubectl delete -f - --ignore-not-found=true 2>&1)
  if [[ $? -ne 0 ]]; then
    warning "Falha ao remover plantsuite. Continuando..."
    echo "$output" >&2
  else
    klog "Plantsuite removido com sucesso."
  fi

  real_wait_namespace_deleted "plantsuite"
  return 0
}

real_execute_step() {
  local step_id="$1"
  REAL_LAST_ERROR=""
  REAL_LAST_DETAIL=""

  if [[ "$step_id" == plantsuite-service:* ]]; then
    local svc="${step_id#plantsuite-service:}"
    # TODO TEMPORÁRIO (MES): Patch MQTT User via kubectl set env.
    # Os serviços MES antigos (controlstations, gateway, wd, production) não concatenam
    # tenantId ao usuário MQTT no código. O Configuration do .NET carrega env vars
    # após appsettings.json, então o secret plantsuite-env (User=system) sobrescreve.
    # Solução: apply → scale-to-0 → kubectl set env → scale-back → wait.
    # O scale-to-0 evita que 2 pods subam em paralelo durante o rollout.
    # NOTA: gateway e wd têm sidecar UI - o patch usa -c para targetar o container principal.
    # REMOVER quando os serviços migrarem para o padrão novo (concatenar tenantId no código).
    case "$svc" in
      controlstations|gateway|wd|production)
        local svc_base="k8s/base/plantsuite/${svc}/"
        local component_path
        component_path=$(real_get_component_path "$svc_base")
        if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
          # Snapshot antes do apply para detectar se o patch já triggerou rollout
          local mes_snapshot
          mes_snapshot=$(real_snapshot_workload_generations "$component_path" "plantsuite")
          real_apply_component "$svc_base" "plantsuite/${svc}" || return $?
          patch_mes_mqtt_user_env "$svc" || return $?
          # O patch_mes_mqtt_user_env já causa rollout via scale-to-0/set env/scale-back,
          # mas precisamos aguardar. Se o snapshot não mudou, forçamos restart extra.
          real_ensure_restart_after_apply "$component_path" "plantsuite" "plantsuite/${svc}" "$mes_snapshot" "300s" || return $?
        else
          real_apply_component "$svc_base" "plantsuite/${svc}" || return $?
          patch_mes_mqtt_user_env "$svc" || return $?
          real_wait_rollouts_from_path "$svc_base" "plantsuite" "plantsuite/${svc}" || return $?
        fi
        ;;
      *)
        real_apply_plantsuite_service "$svc" || return $?
        ;;
    esac
    real_set_status_detail "Etapa $step_id concluída"
    return 0
  fi

  if [[ "$step_id" == plantsuite-delete-service:* ]]; then
    local svc_delete="${step_id#plantsuite-delete-service:}"
    real_delete_plantsuite_service "$svc_delete" || return $?
    real_set_status_detail "Etapa $step_id concluida"
    return 0
  fi

  case "$step_id" in
    metrics-server)
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        real_apply_and_ensure_restart "k8s/base/metrics-server/" "metrics-server" "kube-system" "300s" || return $?
      else
        real_apply_component "k8s/base/metrics-server/" "metrics-server" || return $?
        real_set_status_detail "Aguardando metrics-server ficar disponível..."
        metrics_server_detect_and_fix_tls
        wait_deployment_ready "kube-system" "k8s-app=metrics-server" "metrics-server" "metrics-server" || return $?
      fi
      ;;
    cert-manager-operator)
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        real_apply_and_ensure_restart "k8s/base/cert-manager/" "cert-manager" "cert-manager" "300s" || return $?
        real_set_status_detail "Aguardando cert-manager webhook..."
        wait_cert_manager_webhook_ready || return $?
        real_set_status_detail "Aguardando estabilização do cert-manager webhook (90s)..."
        sleep 90
      else
        real_apply_component "k8s/base/cert-manager/" "cert-manager" || return $?
        real_set_status_detail "Aguardando cert-manager deployment..."
        wait_deployment_ready "cert-manager" "app.kubernetes.io/name=cert-manager" "cert-manager" "cert-manager" || return $?
        real_set_status_detail "Aguardando cert-manager webhook..."
        wait_cert_manager_webhook_ready || return $?
        real_set_status_detail "Aguardando estabilização do cert-manager webhook (90s)..."
        sleep 90
      fi
      ;;
    cert-manager-issuers)
      real_apply_component "k8s/base/cert-manager/issuers/" "cert-manager/issuers" || return $?
      ;;
    istio-system)
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        real_apply_and_ensure_restart "k8s/base/istio-system/" "istio-system" "istio-system" "300s" || return $?
        real_set_status_detail "Aguardando estabilização do istio-system (60s)..."
        sleep 60
      else
        real_apply_component "k8s/base/istio-system/" "istio-system" || return $?
        real_set_status_detail "Aguardando istiod..."
        wait_deployment_ready "istio-system" "app=istiod" "istiod" "istiod" || return $?
        real_set_status_detail "Aguardando istio-cni-node..."
        wait_daemonset_ready "istio-system" "app=istio-cni-node" "istio-cni-node" "istio-cni-node" || return $?
        real_set_status_detail "Aguardando ztunnel..."
        wait_daemonset_ready "istio-system" "app=ztunnel" "ztunnel" "ztunnel" || return $?
        real_set_status_detail "Aguardando estabilização do istio-system (60s)..."
        sleep 60
      fi
      ;;
    istio-ingress)
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        real_apply_and_ensure_restart "k8s/base/istio-ingress/" "istio-ingress" "istio-ingress" "300s" || return $?
      else
        real_apply_component "k8s/base/istio-ingress/" "istio-ingress" || return $?
        real_set_status_detail "Aguardando gateway do istio-ingress..."
        wait_deployment_ready "istio-ingress" "app=gateway" "gateway" "istio-ingress gateway" || return $?
      fi
      ;;
    aspire)
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        real_apply_and_ensure_restart "k8s/base/aspire/" "aspire" "aspire" "300s" || return $?
      else
        real_apply_component "k8s/base/aspire/" "aspire" || return $?
        real_set_status_detail "Aguardando aspire-dashboard..."
        wait_deployment_ready "aspire" "app=aspire-dashboard" "aspire-dashboard" "aspire-dashboard" || return $?
      fi
      ;;
    mongodb-operator)
      real_apply_component "k8s/base/mongodb/" "mongodb" || return $?
      real_set_status_detail "Aguardando mongodb operator..."
      wait_deployment_ready "mongodb" "app.kubernetes.io/name=percona-server-mongodb-operator" "percona-server-mongodb-operator" "percona-server-mongodb-operator" || return $?
      ;;
    mongodb-instance)
      real_apply_component "k8s/base/mongodb/plantsuite-psmdb/" "mongodb/plantsuite-psmdb" || return $?
      real_set_status_detail "Aguardando CR plantsuite-psmdb..."
      wait_psmdb_ready "mongodb" "plantsuite-psmdb" "plantsuite-psmdb (CR)" || return $?
      real_set_status_detail "Aguardando statefulset plantsuite-psmdb..."
      wait_statefulset_ready "mongodb" "app.kubernetes.io/instance=plantsuite-psmdb" "plantsuite-psmdb" "plantsuite-psmdb" || return $?
      ;;
    postgresql-operator)
      real_apply_component "k8s/base/postgresql/" "postgresql" || return $?
      real_set_status_detail "Aguardando postgresql operator..."
      wait_deployment_ready "postgresql" "app.kubernetes.io/name=percona-postgresql-operator" "percona-postgresql-operator" "percona-postgresql-operator" || return $?
      ;;
    postgresql-instance)
      real_apply_component "k8s/base/postgresql/plantsuite-ppgc/" "postgresql/plantsuite-ppgc" || return $?
      real_set_status_detail "Aguardando CR plantsuite-ppgc..."
      wait_postgrescluster_ready "postgresql" "plantsuite-ppgc" "plantsuite-ppgc (CR)" || return $?
      real_set_status_detail "Aguardando statefulset plantsuite-ppgc..."
      wait_statefulset_ready "postgresql" "postgres-operator.crunchydata.com/cluster=plantsuite-ppgc" "plantsuite-ppgc" "plantsuite-ppgc" || return $?
      ;;
    redis)
      generate_secure_password "k8s/base/redis/.env.secret" "password"
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        real_apply_and_ensure_restart "k8s/base/redis/" "redis" "redis" "300s" || return $?
      else
        real_apply_component "k8s/base/redis/" "redis" || return $?
        real_set_status_detail "Aguardando statefulset redis..."
        wait_statefulset_ready "redis" "app=redis" "plantsuite-redis" "redis" || return $?
      fi
      ;;
    keycloak-operator)
      real_apply_component "k8s/base/keycloak/" "keycloak" || return $?
      real_set_status_detail "Aguardando keycloak operator..."
      wait_deployment_ready "keycloak" "app.kubernetes.io/name=keycloak-operator" "keycloak-operator" "keycloak-operator" || return $?
      ;;
    keycloak-instance)
      update_keycloak_secrets
      real_apply_component "k8s/base/keycloak/plantsuite-kc/" "keycloak/plantsuite-kc" || return $?
      real_set_status_detail "Aguardando keycloak plantsuite-kc..."
      wait_keycloak_ready "keycloak" "plantsuite-kc" "plantsuite-kc" || return $?
      real_set_status_detail "Aguardando import do realm keycloak..."
      wait_keycloak_realm_ready "keycloak" "plantsuite-kc-realm" "plantsuite-kc-realm" || return $?
      ;;
    rabbitmq-operator)
      real_apply_component "k8s/base/rabbitmq/" "rabbitmq" || return $?
      real_set_status_detail "Aguardando rabbitmq operator..."
      wait_deployment_ready "rabbitmq" "app.kubernetes.io/name=rabbitmq-cluster-operator" "rabbitmq-cluster-operator" "rabbitmq-cluster-operator" || return $?
      ;;
    rabbitmq-instance)
      real_apply_component "k8s/base/rabbitmq/plantsuite-rmq/" "rabbitmq/plantsuite-rmq" || return $?
      real_set_status_detail "Aguardando CR plantsuite-rmq..."
      wait_rabbitmq_ready "rabbitmq" "plantsuite-rmq" "plantsuite-rmq (CR)" || return $?
      real_set_status_detail "Aguardando statefulset rabbitmq..."
      wait_statefulset_ready "rabbitmq" "app.kubernetes.io/name=plantsuite-rmq" "plantsuite-rmq-server" "plantsuite-rmq" || return $?
      ;;
    vernemq)
      update_vernemq_secrets
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        real_apply_and_ensure_restart "k8s/base/vernemq/" "vernemq" "vernemq" "300s" || return $?
      else
        real_apply_component "k8s/base/vernemq/" "vernemq" || return $?
        real_set_status_detail "Aguardando statefulset vernemq..."
        wait_statefulset_ready "vernemq" "app.kubernetes.io/name=plantsuite-vmq" "plantsuite-vmq" "plantsuite-vmq" || return $?
      fi
      ;;
    plantsuite-base)
      update_plantsuite_env
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        real_apply_and_ensure_restart "k8s/base/plantsuite/" "plantsuite" "plantsuite" "300s" || return $?
      else
        real_apply_component "k8s/base/plantsuite/" "plantsuite" || return $?
        real_set_status_detail "Validando rollouts de plantsuite..."
        real_wait_rollouts_from_path "k8s/base/plantsuite/" "plantsuite" "plantsuite" "300s" || return $?
      fi
      ;;
    plantsuite-delete)
      real_delete_plantsuite_all
      ;;
    metrics-server-delete)
      real_delete_infra_component "k8s/base/metrics-server/" "metrics-server"
      ;;
    cert-manager-delete-issuers)
      real_delete_infra_component "k8s/base/cert-manager/issuers/" "cert-manager/issuers"
      ;;
    cert-manager-delete)
      real_delete_infra_component "k8s/base/cert-manager/" "cert-manager"
      real_wait_namespace_deleted "cert-manager"
      ;;
    istio-system-delete)
      real_delete_infra_component "k8s/base/istio-system/" "istio-system"
      real_wait_namespace_deleted "istio-system"
      ;;
    istio-ingress-delete)
      real_delete_infra_component "k8s/base/istio-ingress/" "istio-ingress"
      real_wait_namespace_deleted "istio-ingress"
      ;;
    aspire-delete)
      real_delete_infra_component "k8s/base/aspire/" "aspire"
      real_wait_namespace_deleted "aspire"
      ;;
    mongodb-delete-instance)
      real_delete_infra_component "k8s/base/mongodb/plantsuite-psmdb/" "mongodb/plantsuite-psmdb"
      real_delete_cr_with_finalizer_handling "psmdb" "plantsuite-psmdb" "mongodb"
      real_wait_statefulset_deleted "mongodb" "app.kubernetes.io/instance=plantsuite-psmdb" "plantsuite-psmdb"
      ;;
    mongodb-delete-operator)
      real_delete_infra_component "k8s/base/mongodb/" "mongodb operator"
      real_wait_namespace_deleted "mongodb"
      ;;
    postgresql-delete-instance)
      real_delete_infra_component "k8s/base/postgresql/plantsuite-ppgc/" "postgresql/plantsuite-ppgc"
      real_delete_cr_with_finalizer_handling "postgrescluster" "plantsuite-ppgc" "postgresql"
      real_wait_statefulset_deleted "postgresql" "postgres-operator.crunchydata.com/cluster=plantsuite-ppgc" "plantsuite-ppgc"
      ;;
    postgresql-delete-operator)
      real_delete_infra_component "k8s/base/postgresql/" "postgresql operator"
      real_wait_namespace_deleted "postgresql"
      ;;
    redis-delete)
      real_delete_infra_component "k8s/base/redis/" "redis"
      real_wait_statefulset_deleted "redis" "app=redis" "plantsuite-redis"
      real_wait_namespace_deleted "redis"
      ;;
    keycloak-delete-instance)
      real_delete_infra_component "k8s/base/keycloak/plantsuite-kc/" "keycloak/plantsuite-kc"
      real_delete_cr_with_finalizer_handling "keycloakrealmimport" "plantsuite-kc-realm" "keycloak"
      real_delete_cr_with_finalizer_handling "keycloak" "plantsuite-kc" "keycloak"
      ;;
    keycloak-delete-operator)
      real_delete_infra_component "k8s/base/keycloak/" "keycloak operator"
      real_wait_namespace_deleted "keycloak"
      ;;
    rabbitmq-delete-instance)
      real_delete_infra_component "k8s/base/rabbitmq/plantsuite-rmq/" "rabbitmq/plantsuite-rmq"
      real_delete_cr_with_finalizer_handling "rabbitmqcluster" "plantsuite-rmq" "rabbitmq"
      real_wait_statefulset_deleted "rabbitmq" "app.kubernetes.io/name=plantsuite-rmq" "plantsuite-rmq"
      ;;
    rabbitmq-delete-operator)
      real_delete_infra_component "k8s/base/rabbitmq/" "rabbitmq operator"
      real_wait_namespace_deleted "rabbitmq"
      ;;
    vernemq-delete)
      real_delete_infra_component "k8s/base/vernemq/" "vernemq"
      real_wait_statefulset_deleted "vernemq" "app.kubernetes.io/name=plantsuite-vmq" "plantsuite-vmq"
      real_wait_namespace_deleted "vernemq"
      ;;
    *)
      REAL_LAST_ERROR="Etapa desconhecida: $step_id"
      return 40
      ;;
  esac

  real_set_status_detail "Etapa $step_id concluída"
  return 0
}
