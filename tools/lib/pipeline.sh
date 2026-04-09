#!/usr/bin/env bash
# tools/lib/pipeline.sh
# Pipeline declarativo de instalação (ordem fixa da infraestrutura).

declare -a REAL_STEP_IDS=()
declare -a REAL_STEP_LABELS=()
REAL_STEP_COUNT=0

build_real_pipeline() {
  REAL_STEP_IDS=()
  REAL_STEP_LABELS=()

  # Ordem baseada no install.sh legado.
  REAL_STEP_IDS+=("metrics-server")
  REAL_STEP_LABELS+=("metrics-server")

  REAL_STEP_IDS+=("cert-manager-operator")
  REAL_STEP_LABELS+=("cert-manager")

  REAL_STEP_IDS+=("cert-manager-issuers")
  REAL_STEP_LABELS+=("cert-manager/issuers")

  REAL_STEP_IDS+=("istio-system")
  REAL_STEP_LABELS+=("istio-system")

  REAL_STEP_IDS+=("istio-ingress")
  REAL_STEP_LABELS+=("istio-ingress")

  REAL_STEP_IDS+=("aspire")
  REAL_STEP_LABELS+=("aspire")

  REAL_STEP_IDS+=("mongodb-operator")
  REAL_STEP_LABELS+=("mongodb")

  REAL_STEP_IDS+=("mongodb-instance")
  REAL_STEP_LABELS+=("mongodb/plantsuite-psmdb")

  REAL_STEP_IDS+=("postgresql-operator")
  REAL_STEP_LABELS+=("postgresql")

  REAL_STEP_IDS+=("postgresql-instance")
  REAL_STEP_LABELS+=("postgresql/plantsuite-ppgc")

  REAL_STEP_IDS+=("redis")
  REAL_STEP_LABELS+=("redis")

  REAL_STEP_IDS+=("keycloak-operator")
  REAL_STEP_LABELS+=("keycloak")

  REAL_STEP_IDS+=("keycloak-instance")
  REAL_STEP_LABELS+=("keycloak/plantsuite-kc")

  REAL_STEP_IDS+=("rabbitmq-operator")
  REAL_STEP_LABELS+=("rabbitmq")

  REAL_STEP_IDS+=("rabbitmq-instance")
  REAL_STEP_LABELS+=("rabbitmq/plantsuite-rmq")

  REAL_STEP_IDS+=("vernemq")
  REAL_STEP_LABELS+=("vernemq")

  # Plantsuite: progresso detalhado por serviço selecionado.
  REAL_STEP_IDS+=("plantsuite-base")
  REAL_STEP_LABELS+=("plantsuite")

  local svc
  for svc in ${SELECTED_SERVICES:-}; do
    REAL_STEP_IDS+=("plantsuite-service:${svc}")
    REAL_STEP_LABELS+=("plantsuite/${svc}")
  done

  REAL_STEP_COUNT=${#REAL_STEP_IDS[@]}
}

append_infra_update_steps() {
  local component="$1"
  case "$component" in
    metrics-server)
      REAL_STEP_IDS+=("metrics-server")
      REAL_STEP_LABELS+=("infra/metrics-server")
      ;;
    cert-manager)
      REAL_STEP_IDS+=("cert-manager-operator" "cert-manager-issuers")
      REAL_STEP_LABELS+=("infra/cert-manager" "infra/cert-manager/issuers")
      ;;
    istio-system)
      REAL_STEP_IDS+=("istio-system")
      REAL_STEP_LABELS+=("infra/istio-system")
      ;;
    istio-ingress)
      REAL_STEP_IDS+=("istio-ingress")
      REAL_STEP_LABELS+=("infra/istio-ingress")
      ;;
    aspire)
      REAL_STEP_IDS+=("aspire")
      REAL_STEP_LABELS+=("infra/aspire")
      ;;
    mongodb)
      REAL_STEP_IDS+=("mongodb-operator" "mongodb-instance")
      REAL_STEP_LABELS+=("infra/mongodb" "infra/mongodb/plantsuite-psmdb")
      ;;
    postgresql)
      REAL_STEP_IDS+=("postgresql-operator" "postgresql-instance")
      REAL_STEP_LABELS+=("infra/postgresql" "infra/postgresql/plantsuite-ppgc")
      ;;
    redis)
      REAL_STEP_IDS+=("redis")
      REAL_STEP_LABELS+=("infra/redis")
      ;;
    keycloak)
      REAL_STEP_IDS+=("keycloak-operator" "keycloak-instance")
      REAL_STEP_LABELS+=("infra/keycloak" "infra/keycloak/plantsuite-kc")
      ;;
    rabbitmq)
      REAL_STEP_IDS+=("rabbitmq-operator" "rabbitmq-instance")
      REAL_STEP_LABELS+=("infra/rabbitmq" "infra/rabbitmq/plantsuite-rmq")
      ;;
    vernemq)
      REAL_STEP_IDS+=("vernemq")
      REAL_STEP_LABELS+=("infra/vernemq")
      ;;
  esac
}

append_infra_delete_steps() {
  local component="$1"
  case "$component" in
    metrics-server)
      REAL_STEP_IDS+=("metrics-server-delete")
      REAL_STEP_LABELS+=("infra/metrics-server (remover)")
      ;;
    cert-manager)
      REAL_STEP_IDS+=("cert-manager-delete-issuers" "cert-manager-delete")
      REAL_STEP_LABELS+=("infra/cert-manager/issuers (remover)" "infra/cert-manager (remover)")
      ;;
    istio-system)
      REAL_STEP_IDS+=("istio-system-delete")
      REAL_STEP_LABELS+=("infra/istio-system (remover)")
      ;;
    istio-ingress)
      REAL_STEP_IDS+=("istio-ingress-delete")
      REAL_STEP_LABELS+=("infra/istio-ingress (remover)")
      ;;
    aspire)
      REAL_STEP_IDS+=("aspire-delete")
      REAL_STEP_LABELS+=("infra/aspire (remover)")
      ;;
    mongodb)
      REAL_STEP_IDS+=("mongodb-delete-instance" "mongodb-delete-operator")
      REAL_STEP_LABELS+=("infra/mongodb/plantsuite-psmdb (remover)" "infra/mongodb (remover)")
      ;;
    postgresql)
      REAL_STEP_IDS+=("postgresql-delete-instance" "postgresql-delete-operator")
      REAL_STEP_LABELS+=("infra/postgresql/plantsuite-ppgc (remover)" "infra/postgresql (remover)")
      ;;
    redis)
      REAL_STEP_IDS+=("redis-delete")
      REAL_STEP_LABELS+=("infra/redis (remover)")
      ;;
    keycloak)
      REAL_STEP_IDS+=("keycloak-delete-instance" "keycloak-delete-operator")
      REAL_STEP_LABELS+=("infra/keycloak/plantsuite-kc (remover)" "infra/keycloak (remover)")
      ;;
    rabbitmq)
      REAL_STEP_IDS+=("rabbitmq-delete-instance" "rabbitmq-delete-operator")
      REAL_STEP_LABELS+=("infra/rabbitmq/plantsuite-rmq (remover)" "infra/rabbitmq (remover)")
      ;;
    vernemq)
      REAL_STEP_IDS+=("vernemq-delete")
      REAL_STEP_LABELS+=("infra/vernemq (remover)")
      ;;
  esac
}

build_infra_delete_pipeline() {
  local -a INFRA_DELETE_REVERSE=(
    "vernemq"
    "rabbitmq"
    "keycloak"
    "redis"
    "postgresql"
    "mongodb"
    "aspire"
    "istio-ingress"
    "istio-system"
    "cert-manager"
    "metrics-server"
  )

  local -a SELECTED_DELETE_ARRAY
  IFS=' ' read -ra SELECTED_DELETE_ARRAY <<< "${UPDATE_SELECTED_INFRA_DELETE:-}"

  local comp
  for comp in "${INFRA_DELETE_REVERSE[@]}"; do
    local found=0
    local s
    for s in "${SELECTED_DELETE_ARRAY[@]}"; do
      if [[ "$s" == "$comp" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 1 ]]; then
      append_infra_delete_steps "$comp"
    fi
  done
}

build_update_pipeline() {
  REAL_STEP_IDS=()
  REAL_STEP_LABELS=()

  local component svc

  if [[ "${REMOVE_ALL_MODE:-false}" == "true" ]]; then
    REAL_STEP_IDS+=("plantsuite-delete")
    REAL_STEP_LABELS+=("plantsuite (remover namespace)")
  else
    local -a DELETE_SVC_ARRAY
    IFS=' ' read -ra DELETE_SVC_ARRAY <<< "${UPDATE_SELECTED_PLANTSUITE_DELETE:-}"
    for ((i=${#DELETE_SVC_ARRAY[@]}-1; i>=0; i--)); do
      svc="${DELETE_SVC_ARRAY[$i]}"
      [[ -n "$svc" ]] || continue
      REAL_STEP_IDS+=("plantsuite-delete-service:${svc}")
      REAL_STEP_LABELS+=("plantsuite/${svc} (remover)")
    done
  fi

  build_infra_delete_pipeline

  for component in ${UPDATE_SELECTED_INFRA_APPLY:-}; do
    append_infra_update_steps "$component"
  done

  if [[ -n "${UPDATE_SELECTED_PLANTSUITE_APPLY:-}" ]]; then
    REAL_STEP_IDS+=("plantsuite-base")
    REAL_STEP_LABELS+=("plantsuite/base")
  fi

  for svc in ${UPDATE_SELECTED_PLANTSUITE_APPLY:-}; do
    REAL_STEP_IDS+=("plantsuite-service:${svc}")
    REAL_STEP_LABELS+=("plantsuite/${svc} (aplicar)")
  done

  REAL_STEP_COUNT=${#REAL_STEP_IDS[@]}
}
