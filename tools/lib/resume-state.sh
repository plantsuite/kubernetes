#!/usr/bin/env bash
# Estado de retomada da instalação, persistido no cluster selecionado.

RESUME_STATE_NAMESPACE="kube-system"
RESUME_STATE_NAME="plantsuite-installer-state"
RESUME_STATE_PRESENT=false
RESUME_STATE_RESUMABLE=false
RESUME_STATE_VERSION=""
RESUME_STATE_OPERATION=""
RESUME_STATE_STATUS=""
RESUME_STATE_OVERLAY=""
RESUME_STATE_SERVICES=""
RESUME_STATE_INFRA_SKIP=""
RESUME_STATE_INFRA_NEVER=""
RESUME_STATE_COMPLETED=""
RESUME_STATE_CURRENT_STEP=""
RESUME_STATE_ERROR=""
RESUME_STATE_DETAIL=""

resume_state_value() {
  local key="$1"
  kubectl -n "$RESUME_STATE_NAMESPACE" get configmap "$RESUME_STATE_NAME" \
    -o "jsonpath={.data.${key}}" 2>/dev/null
}

resume_state_load() {
  RESUME_STATE_PRESENT=false
  RESUME_STATE_RESUMABLE=false

  local output
  if ! output=$(kubectl -n "$RESUME_STATE_NAMESPACE" get configmap "$RESUME_STATE_NAME" 2>&1); then
    if [[ "$output" == *"NotFound"* || "$output" == *"not found"* ]]; then
      return 0
    fi
    error "Não foi possível verificar instalação pendente em ${RESUME_STATE_NAMESPACE}: $output"
    return 1
  fi

  RESUME_STATE_PRESENT=true
  local key value
  for key in version operation status overlay services infra_skip infra_never completed current_step error detail; do
    if ! value=$(resume_state_value "$key"); then
      error "Não foi possível ler o estado da instalação pendente em ${RESUME_STATE_NAMESPACE}. A instalação foi interrompida por segurança."
      return 1
    fi
    printf -v "RESUME_STATE_${key^^}" '%s' "$value"
  done

  case "$RESUME_STATE_STATUS" in
    pending|running|failed|canceled) RESUME_STATE_RESUMABLE=true ;;
    complete) ;;
    *)
      error "O estado da instalação pendente está incompleto. A instalação foi interrompida por segurança."
      return 1
      ;;
  esac

  if [[ "$RESUME_STATE_VERSION" != "1" || "$RESUME_STATE_OPERATION" != "install" || -z "$RESUME_STATE_OVERLAY" || -z "$RESUME_STATE_SERVICES" ]]; then
    error "O estado da instalação pendente está incompleto. A instalação foi interrompida por segurança."
    return 1
  fi
}

resume_state_save() {
  local status="$1"
  local current_step="${2:-$RESUME_STATE_CURRENT_STEP}"
  local error_message="${3:-$RESUME_STATE_ERROR}"
  local detail="${4:-$RESUME_STATE_DETAIL}"
  error_message=$(resume_state_sanitize_detail "$error_message")
  detail=$(resume_state_sanitize_detail "$detail")

  kubectl -n "$RESUME_STATE_NAMESPACE" create configmap "$RESUME_STATE_NAME" \
    --from-literal=version=1 \
    --from-literal=operation=install \
    --from-literal=status="$status" \
    --from-literal=overlay="${SELECTED_OVERLAY:-$RESUME_STATE_OVERLAY}" \
    --from-literal=services="${SELECTED_SERVICES:-$RESUME_STATE_SERVICES}" \
    --from-literal=infra_skip="${GATEWAY_INFRA_SKIP[*]-}" \
    --from-literal=infra_never="${GATEWAY_INFRA_NEVER[*]-}" \
    --from-literal=completed="$RESUME_STATE_COMPLETED" \
    --from-literal=current_step="$current_step" \
    --from-literal=error="$error_message" \
    --from-literal=detail="$detail" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

resume_state_sanitize_detail() {
  local value="$1"
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  value=${value//$'\t'/ }
  value=$(LC_ALL=C printf '%s' "$value" | tr -cd '[:print:] ')
  printf '%s' "${value:0:1024}"
}

resume_state_start() {
  if [[ "${RESUME_INSTALL:-false}" != "true" ]]; then
    RESUME_STATE_COMPLETED=""
    RESUME_STATE_INFRA_SKIP=""
    RESUME_STATE_INFRA_NEVER=""
  fi
  RESUME_STATE_CURRENT_STEP=""
  RESUME_STATE_ERROR=""
  RESUME_STATE_DETAIL=""
  resume_state_save running
}

resume_state_step_completed() {
  local step_id="$1" completed
  for completed in $RESUME_STATE_COMPLETED; do
    [[ "$completed" == "$step_id" ]] && return 0
  done
  return 1
}

resume_state_mark_step_running() {
  RESUME_STATE_CURRENT_STEP="$1"
  resume_state_save running "$1"
}

resume_state_mark_step_complete() {
  local step_id="$1"
  if ! resume_state_step_completed "$step_id"; then
    RESUME_STATE_COMPLETED="${RESUME_STATE_COMPLETED:+$RESUME_STATE_COMPLETED }$step_id"
  fi
  RESUME_STATE_CURRENT_STEP=""
  resume_state_save running
}

resume_state_mark_failed() {
  local status="$1" error_message="$2" detail="${3:-}"
  RESUME_STATE_ERROR="$error_message"
  RESUME_STATE_DETAIL="$detail"
  resume_state_save "$status" "$RESUME_STATE_CURRENT_STEP" "$error_message" "$detail"
}

resume_state_mark_prereq_failed() {
  RESUME_STATE_CURRENT_STEP="prerequisites"
  resume_state_mark_failed failed "$1" "${2:-}"
}

resume_state_mark_complete() {
  RESUME_STATE_CURRENT_STEP=""
  RESUME_STATE_ERROR=""
  RESUME_STATE_DETAIL=""
  resume_state_save complete
}

resume_state_restore_selection() {
  SELECTED_SERVICES="$RESUME_STATE_SERVICES"
  IFS=' ' read -ra GATEWAY_INFRA_SKIP <<< "$RESUME_STATE_INFRA_SKIP"
  IFS=' ' read -ra GATEWAY_INFRA_NEVER <<< "$RESUME_STATE_INFRA_NEVER"
  export SELECTED_SERVICES GATEWAY_INFRA_SKIP GATEWAY_INFRA_NEVER
}

resume_state_prompt() {
  printf '\n[AVISO] Instalação anterior incompleta detectada (etapa: %s).\n' "${RESUME_STATE_CURRENT_STEP:-desconhecida}"
  [[ -n "$RESUME_STATE_ERROR" ]] && printf '[AVISO] Último erro: %s\n' "$RESUME_STATE_ERROR"
  read -rp "Retomar a instalação preservando as etapas concluídas? (s/n): " -n 1 answer
  printf '\n'
  [[ "$answer" =~ [sS] ]]
}
