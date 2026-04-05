#!/usr/bin/env bash
# tools/lib/update-detect.sh
# Detecao de recursos existentes para decidir instalacao x atualizacao
# e preencher estados de infra/servicos plantsuite.

# Estados agregados exportados para as telas de update.
UPDATE_INFRA_INSTALLED=""
UPDATE_INFRA_DEGRADED=""
UPDATE_INFRA_ABSENT=""

UPDATE_SVC_INSTALLED=""
UPDATE_SVC_DEGRADED=""
UPDATE_SVC_ABSENT=""
UPDATE_DETECTED_MODE="install"

# Lista canonica de servicos Plantsuite para update.
declare -a UPDATE_PLANTSUITE_SERVICES=(
  "alarms" "controlstation" "dashboards" "devices" "entities"
  "gateway" "mes" "notifications" "portal" "production"
  "queries" "spc" "tenants" "timeseries-buffer" "timeseries-mqtt"
  "wd" "workflows"
)

list_contains_word() {
  local list="$1"
  local item="$2"
  local cur
  for cur in $list; do
    [[ "$cur" == "$item" ]] && return 0
  done
  return 1
}

append_word() {
  local list="$1"
  local item="$2"
  if [[ -z "$list" ]]; then
    printf '%s' "$item"
  else
    printf '%s %s' "$list" "$item"
  fi
}

resource_exists_ns() {
  local kind="$1"
  local name="$2"
  local namespace="$3"

  kubectl get "$kind" "$name" -n "$namespace" >/dev/null 2>&1
}

probe_deployment_state() {
  local namespace="$1"
  local name="$2"

  if ! kubectl get deployment "$name" -n "$namespace" >/dev/null 2>&1; then
    echo "absent"
    return 0
  fi

  local replicas ready
  replicas=$(kubectl get deployment "$name" -n "$namespace" -o jsonpath='{.status.replicas}' 2>/dev/null || true)
  ready=$(kubectl get deployment "$name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)

  replicas=${replicas:-0}
  ready=${ready:-0}

  if [[ "$replicas" -gt 0 && "$ready" -ge "$replicas" ]]; then
    echo "installed"
  else
    echo "degraded"
  fi
}

probe_statefulset_state() {
  local namespace="$1"
  local name="$2"

  if ! kubectl get statefulset "$name" -n "$namespace" >/dev/null 2>&1; then
    echo "absent"
    return 0
  fi

  local replicas ready
  replicas=$(kubectl get statefulset "$name" -n "$namespace" -o jsonpath='{.status.replicas}' 2>/dev/null || true)
  ready=$(kubectl get statefulset "$name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)

  replicas=${replicas:-0}
  ready=${ready:-0}

  if [[ "$replicas" -gt 0 && "$ready" -ge "$replicas" ]]; then
    echo "installed"
  else
    echo "degraded"
  fi
}

set_infra_state() {
  local component="$1"
  local state="$2"
  case "$state" in
    installed)
      UPDATE_INFRA_INSTALLED=$(append_word "$UPDATE_INFRA_INSTALLED" "$component")
      ;;
    degraded)
      UPDATE_INFRA_DEGRADED=$(append_word "$UPDATE_INFRA_DEGRADED" "$component")
      ;;
    *)
      UPDATE_INFRA_ABSENT=$(append_word "$UPDATE_INFRA_ABSENT" "$component")
      ;;
  esac
}

set_service_state() {
  local svc="$1"
  local state="$2"
  case "$state" in
    installed)
      UPDATE_SVC_INSTALLED=$(append_word "$UPDATE_SVC_INSTALLED" "$svc")
      ;;
    degraded)
      UPDATE_SVC_DEGRADED=$(append_word "$UPDATE_SVC_DEGRADED" "$svc")
      ;;
    *)
      UPDATE_SVC_ABSENT=$(append_word "$UPDATE_SVC_ABSENT" "$svc")
      ;;
  esac
}

detect_infra_component_state() {
  local component="$1"
  local state="absent"

  case "$component" in
    metrics-server)
      state=$(probe_deployment_state "kube-system" "metrics-server")
      ;;
    cert-manager)
      state=$(probe_deployment_state "cert-manager" "cert-manager")
      ;;
    istio-system)
      state=$(probe_deployment_state "istio-system" "istiod")
      ;;
    istio-ingress)
      state=$(probe_deployment_state "istio-ingress" "gateway")
      ;;
    aspire)
      state=$(probe_deployment_state "aspire" "dashboard")
      if [[ "$state" == "absent" ]]; then
        # Compatibilidade com clusters antigos que ainda usam o nome aspire-dashboard.
        state=$(probe_deployment_state "aspire" "aspire-dashboard")
      fi
      ;;
    mongodb)
      local op_state has_cr
      op_state=$(probe_deployment_state "mongodb" "percona-server-mongodb-operator")
      has_cr=0
      resource_exists_ns "psmdb" "plantsuite-psmdb" "mongodb" && has_cr=1
      if [[ "$op_state" == "installed" && "$has_cr" -eq 1 ]]; then
        state="installed"
      elif [[ "$op_state" != "absent" || "$has_cr" -eq 1 ]]; then
        state="degraded"
      else
        state="absent"
      fi
      ;;
    postgresql)
      local pg_op_state has_pg_cr
      pg_op_state=$(probe_deployment_state "postgresql" "percona-postgresql-operator")
      has_pg_cr=0
      resource_exists_ns "postgrescluster" "plantsuite-ppgc" "postgresql" && has_pg_cr=1
      if [[ "$pg_op_state" == "installed" && "$has_pg_cr" -eq 1 ]]; then
        state="installed"
      elif [[ "$pg_op_state" != "absent" || "$has_pg_cr" -eq 1 ]]; then
        state="degraded"
      else
        state="absent"
      fi
      ;;
    redis)
      state=$(probe_statefulset_state "redis" "plantsuite-redis")
      ;;
    keycloak)
      local kc_op_state has_kc_cr
      kc_op_state=$(probe_deployment_state "keycloak" "keycloak-operator")
      has_kc_cr=0
      resource_exists_ns "keycloak" "plantsuite-kc" "keycloak" && has_kc_cr=1
      if [[ "$kc_op_state" == "installed" && "$has_kc_cr" -eq 1 ]]; then
        state="installed"
      elif [[ "$kc_op_state" != "absent" || "$has_kc_cr" -eq 1 ]]; then
        state="degraded"
      else
        state="absent"
      fi
      ;;
    rabbitmq)
      local rmq_op_state has_rmq_cr
      rmq_op_state=$(probe_deployment_state "rabbitmq" "rabbitmq-cluster-operator")
      has_rmq_cr=0
      resource_exists_ns "rabbitmqcluster" "plantsuite-rmq" "rabbitmq" && has_rmq_cr=1
      if [[ "$rmq_op_state" == "installed" && "$has_rmq_cr" -eq 1 ]]; then
        state="installed"
      elif [[ "$rmq_op_state" != "absent" || "$has_rmq_cr" -eq 1 ]]; then
        state="degraded"
      else
        state="absent"
      fi
      ;;
    vernemq)
      state=$(probe_statefulset_state "vernemq" "plantsuite-vmq")
      ;;
    *)
      state="absent"
      ;;
  esac

  echo "$state"
}

detect_plantsuite_service_state() {
  local svc="$1"

  local dep_state sts_state
  dep_state=$(probe_deployment_state "plantsuite" "$svc")
  if [[ "$dep_state" == "installed" || "$dep_state" == "degraded" ]]; then
    echo "$dep_state"
    return 0
  fi

  sts_state=$(probe_statefulset_state "plantsuite" "$svc")
  if [[ "$sts_state" == "installed" || "$sts_state" == "degraded" ]]; then
    echo "$sts_state"
    return 0
  fi

  echo "absent"
}

detect_cluster_inventory() {
  UPDATE_INFRA_INSTALLED=""
  UPDATE_INFRA_DEGRADED=""
  UPDATE_INFRA_ABSENT=""

  UPDATE_SVC_INSTALLED=""
  UPDATE_SVC_DEGRADED=""
  UPDATE_SVC_ABSENT=""

  local component state svc
  for component in "${INFRA_COMPONENTS[@]}"; do
    state=$(detect_infra_component_state "$component")
    set_infra_state "$component" "$state"
  done

  for svc in "${UPDATE_PLANTSUITE_SERVICES[@]}"; do
    state=$(detect_plantsuite_service_state "$svc")
    set_service_state "$svc" "$state"
  done
}

detect_auto_mode() {
  detect_cluster_inventory

  # Modo "update" somente se houver servicos nao-obrigatorios instalados/degradados.
  # Servicos obrigatorios (infra, tenants e portal) nao contam para essa decisao:
  # se apenas eles estiverem presentes — ou ate faltarem — tratamos como instalacao
  # zerada para consertar tudo de uma vez.
  local mandatory_services="tenants portal"
  local non_mandatory_found=""
  local svc
  for svc in $UPDATE_SVC_INSTALLED $UPDATE_SVC_DEGRADED; do
    if ! list_contains_word "$mandatory_services" "$svc"; then
      non_mandatory_found=$(append_word "$non_mandatory_found" "$svc")
    fi
  done

  if [[ -n "$non_mandatory_found" ]]; then
    UPDATE_DETECTED_MODE="update"
  else
    UPDATE_DETECTED_MODE="install"
  fi

  echo "$UPDATE_DETECTED_MODE"
}
