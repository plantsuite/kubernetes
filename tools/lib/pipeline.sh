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

  REAL_STEP_IDS+=("cert-manager")
  REAL_STEP_LABELS+=("cert-manager + issuers")

  REAL_STEP_IDS+=("istio-system")
  REAL_STEP_LABELS+=("istio-system")

  REAL_STEP_IDS+=("istio-ingress")
  REAL_STEP_LABELS+=("istio-ingress")

  REAL_STEP_IDS+=("aspire")
  REAL_STEP_LABELS+=("aspire")

  REAL_STEP_IDS+=("mongodb")
  REAL_STEP_LABELS+=("mongodb (operator + plantsuite-psmdb)")

  REAL_STEP_IDS+=("postgresql")
  REAL_STEP_LABELS+=("postgresql (operator + plantsuite-ppgc)")

  REAL_STEP_IDS+=("redis")
  REAL_STEP_LABELS+=("redis")

  REAL_STEP_IDS+=("keycloak")
  REAL_STEP_LABELS+=("keycloak (operator + plantsuite-kc)")

  REAL_STEP_IDS+=("rabbitmq")
  REAL_STEP_LABELS+=("rabbitmq (operator + plantsuite-rmq)")

  REAL_STEP_IDS+=("vernemq")
  REAL_STEP_LABELS+=("vernemq")

  # Plantsuite: progresso detalhado por serviço selecionado.
  REAL_STEP_IDS+=("plantsuite-base")
  REAL_STEP_LABELS+=("plantsuite (principal)")

  local svc
  for svc in ${SELECTED_SERVICES:-}; do
    REAL_STEP_IDS+=("plantsuite-service:${svc}")
    REAL_STEP_LABELS+=("plantsuite/${svc}")
  done

  REAL_STEP_IDS+=("plantsuite-ready")
  REAL_STEP_LABELS+=("plantsuite (verificação final)")

  REAL_STEP_COUNT=${#REAL_STEP_IDS[@]}
}
