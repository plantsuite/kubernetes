#!/usr/bin/env bash
# tools/lib/k8s-adapter.sh
# Adapter da execução real (kubectl/helm/waits/secrets).

# shellcheck source=metrics-server-tls-fix.sh
source "$(dirname "${BASH_SOURCE[0]}")/metrics-server-tls-fix.sh"
# shellcheck source=k8s-wait.sh
source "$(dirname "${BASH_SOURCE[0]}")/k8s-wait.sh"
# shellcheck source=secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"

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
    local overlay_path="k8s/overlays/${SELECTED_OVERLAY}/${relative_path}"

    if [[ -d "$overlay_path" ]] && [[ -f "${overlay_path}kustomization.yaml" || -f "${overlay_path}kustomization.yml" || -f "${overlay_path}Kustomization" ]]; then
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

real_apply_plantsuite_selected() {
  # Regra: aplica o kustomization principal sempre,
  # depois aplica apenas os serviços selecionados individualmente.
  real_apply_component "k8s/base/plantsuite/" "plantsuite (principal)" || return $?

  local svc
  for svc in $SELECTED_SERVICES; do
    # Portal e tenants já são aplicados no kustomization principal.
    if [[ "$svc" == "portal" || "$svc" == "tenants" ]]; then
      continue
    fi

    local svc_base="k8s/base/plantsuite/$svc/"
    if [[ ! -d "$svc_base" ]]; then
      REAL_LAST_ERROR="Serviço PlantSuite desconhecido: $svc"
      return 40
    fi

    real_apply_component "$svc_base" "plantsuite/$svc" || return $?
  done

  return 0
}

real_apply_plantsuite_service() {
  local svc="$1"

  if [[ -z "$svc" ]]; then
    REAL_LAST_ERROR="Serviço PlantSuite não informado"
    return 40
  fi

  # Portal e tenants já entram via kustomization principal.
  if [[ "$svc" == "portal" || "$svc" == "tenants" ]]; then
    real_set_status_detail "plantsuite/$svc já incluído no principal"
    return 0
  fi

  local svc_base="k8s/base/plantsuite/$svc/"
  if [[ ! -d "$svc_base" ]]; then
    REAL_LAST_ERROR="Serviço PlantSuite desconhecido: $svc"
    return 40
  fi

  real_apply_component "$svc_base" "plantsuite/$svc" || return $?
  return 0
}

real_execute_step() {
  local step_id="$1"
  REAL_LAST_ERROR=""
  REAL_LAST_DETAIL=""

  if [[ "$step_id" == plantsuite-service:* ]]; then
    local svc="${step_id#plantsuite-service:}"
    real_apply_plantsuite_service "$svc" || return $?
    real_set_status_detail "Etapa $step_id concluída"
    return 0
  fi

  case "$step_id" in
    metrics-server)
      real_apply_component "k8s/base/metrics-server/" "metrics-server" || return $?
      real_set_status_detail "Aguardando metrics-server ficar disponível..."
      metrics_server_detect_and_fix_tls
      wait_deployment_ready "kube-system" "k8s-app=metrics-server" "metrics-server" "metrics-server"
      ;;
    cert-manager)
      real_apply_component "k8s/base/cert-manager/" "cert-manager" || return $?
      real_set_status_detail "Aguardando cert-manager deployment..."
      wait_deployment_ready "cert-manager" "app.kubernetes.io/name=cert-manager" "cert-manager" "cert-manager"
      real_set_status_detail "Aguardando cert-manager webhook..."
      wait_cert_manager_webhook_ready
      real_set_status_detail "Aguardando estabilização do cert-manager webhook (90s)..."
      sleep 90
      real_apply_component "k8s/base/cert-manager/issuers/" "cert-manager issuers" || return $?
      ;;
    istio-system)
      real_apply_component "k8s/base/istio-system/" "istio-system" || return $?
      real_set_status_detail "Aguardando istiod..."
      wait_deployment_ready "istio-system" "app=istiod" "istiod" "istiod"
      real_set_status_detail "Aguardando istio-cni-node..."
      wait_daemonset_ready "istio-system" "app=istio-cni-node" "istio-cni-node" "istio-cni-node"
      real_set_status_detail "Aguardando ztunnel..."
      wait_daemonset_ready "istio-system" "app=ztunnel" "ztunnel" "ztunnel"
      real_set_status_detail "Aguardando estabilização do istio-system (60s)..."
      sleep 60
      ;;
    istio-ingress)
      real_apply_component "k8s/base/istio-ingress/" "istio-ingress" || return $?
      real_set_status_detail "Aguardando gateway do istio-ingress..."
      wait_deployment_ready "istio-ingress" "app=gateway" "gateway" "istio-ingress gateway"
      ;;
    aspire)
      real_apply_component "k8s/base/aspire/" "aspire" || return $?
      real_set_status_detail "Aguardando aspire-dashboard..."
      wait_deployment_ready "aspire" "app=aspire-dashboard" "aspire-dashboard" "aspire-dashboard"
      ;;
    mongodb)
      real_apply_component "k8s/base/mongodb/" "mongodb operator" || return $?
      real_set_status_detail "Aguardando mongodb operator..."
      wait_deployment_ready "mongodb" "app.kubernetes.io/name=percona-server-mongodb-operator" "percona-server-mongodb-operator" "percona-server-mongodb-operator"
      real_apply_component "k8s/base/mongodb/plantsuite-psmdb/" "plantsuite-psmdb" || return $?
      real_set_status_detail "Aguardando CR plantsuite-psmdb..."
      wait_psmdb_ready "mongodb" "plantsuite-psmdb" "plantsuite-psmdb (CR)"
      real_set_status_detail "Aguardando statefulset plantsuite-psmdb..."
      wait_statefulset_ready "mongodb" "app.kubernetes.io/instance=plantsuite-psmdb" "plantsuite-psmdb" "plantsuite-psmdb"
      ;;
    postgresql)
      real_apply_component "k8s/base/postgresql/" "postgresql operator" || return $?
      real_set_status_detail "Aguardando postgresql operator..."
      wait_deployment_ready "postgresql" "app.kubernetes.io/name=percona-postgresql-operator" "percona-postgresql-operator" "percona-postgresql-operator"
      real_apply_component "k8s/base/postgresql/plantsuite-ppgc/" "plantsuite-ppgc" || return $?
      real_set_status_detail "Aguardando CR plantsuite-ppgc..."
      wait_postgrescluster_ready "postgresql" "plantsuite-ppgc" "plantsuite-ppgc (CR)"
      real_set_status_detail "Aguardando statefulset plantsuite-ppgc..."
      wait_statefulset_ready "postgresql" "postgres-operator.crunchydata.com/cluster=plantsuite-ppgc" "plantsuite-ppgc" "plantsuite-ppgc"
      ;;
    redis)
      generate_secure_password "k8s/base/redis/.env.secret" "password"
      real_apply_component "k8s/base/redis/" "redis" || return $?
      real_set_status_detail "Aguardando statefulset redis..."
      wait_statefulset_ready "redis" "app=redis" "plantsuite-redis" "redis"
      ;;
    keycloak)
      real_apply_component "k8s/base/keycloak/" "keycloak operator" || return $?
      real_set_status_detail "Aguardando keycloak operator..."
      wait_deployment_ready "keycloak" "app.kubernetes.io/name=keycloak-operator" "keycloak-operator" "keycloak-operator"
      update_keycloak_secrets
      real_apply_component "k8s/base/keycloak/plantsuite-kc/" "plantsuite-kc" || return $?
      real_set_status_detail "Aguardando keycloak plantsuite-kc..."
      wait_keycloak_ready "keycloak" "plantsuite-kc" "plantsuite-kc"
      real_set_status_detail "Aguardando import do realm keycloak..."
      wait_keycloak_realm_ready "keycloak" "plantsuite-kc-realm" "plantsuite-kc-realm"
      ;;
    rabbitmq)
      real_apply_component "k8s/base/rabbitmq/" "rabbitmq operator" || return $?
      real_set_status_detail "Aguardando rabbitmq operator..."
      wait_deployment_ready "rabbitmq" "app.kubernetes.io/name=rabbitmq-cluster-operator" "rabbitmq-cluster-operator" "rabbitmq-cluster-operator"
      real_apply_component "k8s/base/rabbitmq/plantsuite-rmq/" "plantsuite-rmq" || return $?
      real_set_status_detail "Aguardando CR plantsuite-rmq..."
      wait_rabbitmq_ready "rabbitmq" "plantsuite-rmq" "plantsuite-rmq (CR)"
      real_set_status_detail "Aguardando statefulset rabbitmq..."
      wait_statefulset_ready "rabbitmq" "app.kubernetes.io/name=plantsuite-rmq" "plantsuite-rmq-server" "plantsuite-rmq"
      ;;
    vernemq)
      update_vernemq_secrets
      real_apply_component "k8s/base/vernemq/" "vernemq" || return $?
      real_set_status_detail "Aguardando statefulset vernemq..."
      wait_statefulset_ready "vernemq" "app.kubernetes.io/name=plantsuite-vmq" "plantsuite-vmq" "plantsuite-vmq"
      ;;
    plantsuite-base)
      update_plantsuite_env
      real_apply_component "k8s/base/plantsuite/" "plantsuite (principal)" || return $?
      ;;
    plantsuite-ready)
      real_set_status_detail "Aguardando componentes Plantsuite..."
      wait_plantsuite_components_ready
      ;;
    *)
      REAL_LAST_ERROR="Etapa desconhecida: $step_id"
      return 40
      ;;
  esac

  real_set_status_detail "Etapa $step_id concluída"
  return 0
}
