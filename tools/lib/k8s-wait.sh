#!/usr/bin/env bash
# =============================================================================
# k8s-wait.sh — Funções de espera e verificação de recursos Kubernetes
#
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/lib/k8s-wait.sh"
#
# Depende de: klog, warning, error, cl_printf  (definidos em install.sh)
# =============================================================================

# Aguarda um intervalo fixo exibindo spinner sem prefixo e limpa a linha ao concluir
wait_with_spinner() {
  local seconds="$1"
  local message="$2"
  local elapsed=0
  local interval=1
  local spinner=("|" "/" "-" "\\")

  while [ $elapsed -lt $seconds ]; do
    idx=$(( (elapsed / interval) % 4 ))
    remaining=$((seconds - elapsed))
    cl_printf "%s (restam %ss) %s" "$message" "$remaining" "${spinner[$idx]}"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  printf "\r\033[K"
}

# Função para perguntar ao usuário como proceder quando um recurso não fica pronto
handle_timeout() {
  local resource_name="$1"
  while true; do
    echo ""
    echo "⚠️  $resource_name não ficou pronto dentro do tempo esperado."
    echo ""
    echo "O que deseja fazer?"
    echo "  1) Continuar com a execução (sem garantia de funcionamento)"
    echo "  2) Encerrar o script"
    echo "  3) Aguardar novamente ($timeout segundos)"
    echo ""
    read -p "Digite sua escolha (1/2/3): " choice

    case $choice in
      1)
        klog "$resource_name: continuando com a execução..."
        return 0
        ;;
      2)
        error "Instalação interrompida pelo usuário."
        exit 1
        ;;
      3)
        klog "$resource_name: aguardando novamente..."
        return 1
        ;;
      *)
        echo "Opção inválida. Tente novamente."
        ;;
    esac
  done
}

# Checa rapidamente se um Deployment está pronto
is_deployment_ready() {
  local namespace="$1"
  local name="$2"

  local desired ready
  desired=$(kubectl get deploy "$name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  ready=$(kubectl get deploy "$name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)

  if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" = "$ready" ] && [ "$ready" -gt 0 ]; then
    return 0
  fi
  return 1
}

# Checa rapidamente se um StatefulSet está pronto
is_statefulset_ready() {
  local namespace="$1"
  local name="$2"

  local desired ready
  desired=$(kubectl get sts "$name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  ready=$(kubectl get sts "$name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)

  if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" = "$ready" ] && [ "$ready" -gt 0 ]; then
    return 0
  fi
  return 1
}

# Função para aguardar deployment com spinner e tratamento de timeout interativo
wait_deployment_ready() {
  local namespace="$1"
  local label_selector="$2"
  local fallback_name="$3"
  local display_name="$4"
  local timeout=120
  local interval=2
  local elapsed=0
  local spinner=("|" "/" "-" "\\")
  local deploy_name=""

  deploy_name=$(kubectl get deploy -n "$namespace" -l "$label_selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$deploy_name" ]; then
    deploy_name="$fallback_name"
  fi

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      ready=$(kubectl get deploy "$deploy_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
      if [ "$ready" = "True" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\r\033[KAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar DaemonSet com spinner e tratamento de timeout interativo
wait_daemonset_ready() {
  local namespace="$1"
  local label_selector="$2"
  local fallback_name="$3"
  local display_name="$4"
  local timeout=120
  local interval=2
  local elapsed=0
  local spinner=("|" "/" "-" "\\")
  local daemonset_name=""

  daemonset_name=$(kubectl get ds -n "$namespace" -l "$label_selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$daemonset_name" ]; then
    daemonset_name="$fallback_name"
  fi

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      desired=$(kubectl get ds "$daemonset_name" -n "$namespace" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
      ready=$(kubectl get ds "$daemonset_name" -n "$namespace" -o jsonpath='{.status.numberReady}' 2>/dev/null)

      if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" -eq "$ready" ] && [ "$ready" -gt 0 ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\r\033[KAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar StatefulSet com spinner e tratamento de timeout interativo
wait_statefulset_ready() {
  local namespace="$1"
  local label_selector="$2"
  local fallback_name="$3"
  local display_name="$4"
  local timeout=300
  local interval=3
  local elapsed=0
  local spinner=("|" "/" "-" "\\")
  local sts_name=""

  sts_name=$(kubectl get sts -n "$namespace" -l "$label_selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$sts_name" ]; then
    sts_name="$fallback_name"
  fi

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      desired=$(kubectl get sts "$sts_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
      ready=$(kubectl get sts "$sts_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" = "$ready" ] && [ "$ready" -gt 0 ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      cl_printf "Aguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar o webhook do cert-manager ficar pronto (usando apenas kubectl)
wait_cert_manager_webhook_ready() {
  local namespace="cert-manager"
  local service="cert-manager-webhook"
  local timeout=60
  local elapsed=0
  local interval=2
  local spinner=("|" "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      endpoints=$(kubectl get endpoints "$service" -n "$namespace" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
      if [ -n "$endpoints" ]; then
        printf "\r\033[K"
        klog "cert-manager webhook está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      cl_printf "Aguardando cert-manager webhook... %s" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "cert-manager webhook"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar PerconaServerMongoDB (CR) ficar pronto
wait_psmdb_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|" "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      state=$(kubectl get psmdb "$name" -n "$namespace" -o jsonpath='{.status.state}' 2>/dev/null)
      if [ "$state" = "ready" ] || [ "$state" = "clusterInitializing" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto (estado: $state)."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      cl_printf "Aguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar PerconaPGCluster (CR) ficar pronto
wait_postgrescluster_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|" "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      state=$(kubectl get perconapgcluster "$name" -n "$namespace" -o jsonpath='{.status.state}' 2>/dev/null)
      if [ "$state" = "ready" ] || [ "$state" = "updating" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto (estado: $state)."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      cl_printf "Aguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar Keycloak (CR) ficar pronto
wait_keycloak_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|" "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      status=$(kubectl get keycloak "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [ "$status" = "True" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      cl_printf "Aguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar KeycloakRealmImport (CR) ficar pronto
wait_keycloak_realm_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|" "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      status=$(kubectl get keycloakrealmimport "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)
      if [ "$status" = "True" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      cl_printf "Aguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar RabbitmqCluster (CR) ficar pronto
wait_rabbitmq_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|" "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      status=$(kubectl get rabbitmqcluster "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="AllReplicasReady")].status}' 2>/dev/null)
      if [ "$status" = "True" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      cl_printf "Aguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Aguarda todos os Deployments/StatefulSets do Plantsuite em paralelo, reportando progresso
wait_plantsuite_components_ready() {
  local namespace="plantsuite"
  local timeout=900
  local interval=5
  local start_ts=$(date +%s)

  deployments=()
  tempfile_deploy=$(mktemp)
  kubectl get deploy -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null > "$tempfile_deploy"
  while IFS= read -r line; do
    [ -n "$line" ] && deployments+=("$line")
  done < "$tempfile_deploy"
  rm -f "$tempfile_deploy"

  statefulsets=()
  tempfile_sts=$(mktemp)
  kubectl get sts -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null > "$tempfile_sts"
  while IFS= read -r line; do
    [ -n "$line" ] && statefulsets+=("$line")
  done < "$tempfile_sts"
  rm -f "$tempfile_sts"

  local pending=()
  local item
  for item in "${deployments[@]}"; do
    [ -n "$item" ] && pending+=("deploy:${item}")
  done
  for item in "${statefulsets[@]}"; do
    [ -n "$item" ] && pending+=("sts:${item}")
  done

  if [ ${#pending[@]} -eq 0 ]; then
    klog "Componentes do PlantSuite estão prontos."
    return 0
  fi

  klog "Aguardando componentes do Plantsuite ficarem prontos..."

  while [ ${#pending[@]} -gt 0 ]; do
    local new_pending=()
    for item in "${pending[@]}"; do
      IFS=":" read -r kind name <<<"$item"
      if [ "$kind" = "deploy" ]; then
        if is_deployment_ready "$namespace" "$name"; then
          continue
        fi
      else
        if is_statefulset_ready "$namespace" "$name"; then
          continue
        fi
      fi
      new_pending+=("$item")
    done

    pending=("${new_pending[@]}")
    if [ ${#pending[@]} -eq 0 ]; then
      cl_printf "\033[K"
      break
    fi

    local elapsed=$(( $(date +%s) - start_ts ))
    if [ $elapsed -ge $timeout ]; then
      cl_printf "\033[K"
      handle_timeout "Plantsuite (pendentes: ${pending[*]})"
      start_ts=$(date +%s)
    fi

    cl_printf "Aguardando componentes do Plantsuite: %s" "$(printf '%s ' "${pending[@]#*:}")"
    sleep $interval
  done
  cl_printf "\033[K"
  klog "Componentes do PlantSuite estão prontos."
}
