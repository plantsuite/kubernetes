#!/usr/bin/env bash
set -euo pipefail

error() { :; }
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/resume-state.sh"

RESUME_STATE_COMPLETED="cert-manager-operator istio-system"
resume_state_step_completed cert-manager-operator
! resume_state_step_completed redis

RESUME_STATE_SERVICES="gateway devices"
RESUME_STATE_INFRA_SKIP="redis mongodb"
RESUME_STATE_INFRA_NEVER="keycloak postgresql"
resume_state_restore_selection
[[ "$SELECTED_SERVICES" == "gateway devices" ]]
[[ "${GATEWAY_INFRA_SKIP[*]}" == "redis mongodb" ]]
[[ "${GATEWAY_INFRA_NEVER[*]}" == "keycloak postgresql" ]]

calls=$(mktemp)
trap 'rm -f "$calls"' EXIT
MOCK_KUBECTL_MODE=save
kubectl() {
  case "$MOCK_KUBECTL_MODE" in
    save)
      printf '%s\n' "$@" >> "$calls"
      ;;
    read-failure)
      if [[ "$*" == *"-o jsonpath="* ]]; then
        return 1
      fi
      printf 'configmap/%s\n' "$RESUME_STATE_NAME"
      ;;
    incomplete-read)
      if [[ "$*" == *"-o jsonpath="* ]]; then
        [[ "$*" == *".data.status"* ]] && printf 'running'
        return 0
      fi
      printf 'configmap/%s\n' "$RESUME_STATE_NAME"
      ;;
    write-failure)
      if [[ "${1:-}" == "apply" ]]; then
        return 1
      fi
      ;;
  esac
}
SELECTED_OVERLAY=demo
RESUME_STATE_COMPLETED="cert-manager-operator"
GATEWAY_INFRA_SKIP=(redis)
GATEWAY_INFRA_NEVER=(keycloak)
resume_state_save running cert-manager-issuers
saved_args=$(<"$calls")
[[ "$saved_args" == *"--from-literal=status=running"* ]]
[[ "$saved_args" == *"--from-literal=completed=cert-manager-operator"* ]]
[[ "$saved_args" == *"--from-literal=current_step=cert-manager-issuers"* ]]

# Uma instalação nova não pode reutilizar seleções opcionais persistidas.
RESUME_INSTALL=false
RESUME_STATE_INFRA_SKIP="redis mongodb"
RESUME_STATE_INFRA_NEVER="keycloak postgresql"
GATEWAY_INFRA_SKIP=()
GATEWAY_INFRA_NEVER=()
: > "$calls"
resume_state_start
saved_args=$(<"$calls")
[[ "$saved_args" == *"--from-literal=infra_skip="* ]]
[[ "$saved_args" == *"--from-literal=infra_never="* ]]
[[ "$saved_args" != *"--from-literal=infra_skip=redis mongodb"* ]]
[[ "$saved_args" != *"--from-literal=infra_never=keycloak postgresql"* ]]

# Uma leitura parcial do ConfigMap interrompe o fluxo em vez de assumir estado vazio.
MOCK_KUBECTL_MODE=read-failure
RESUME_STATE_PRESENT=false
! resume_state_load
[[ "$RESUME_STATE_PRESENT" == "true" ]]

# Um ConfigMap sem os campos obrigatórios também não é estado vazio.
MOCK_KUBECTL_MODE=incomplete-read
! resume_state_load

# Falha ao aplicar o ConfigMap é propagada ao chamador.
MOCK_KUBECTL_MODE=write-failure
! resume_state_save running

# Diagnósticos persistidos são normalizados e limitados.
MOCK_KUBECTL_MODE=save
: > "$calls"
resume_state_mark_failed failed $'erro\ncompleto' "$(printf 'x%.0s' {1..1100})"
saved_args=$(<"$calls")
[[ "$saved_args" == *"--from-literal=error=erro completo"* ]]
detail=${saved_args#*--from-literal=detail=}
detail=${detail%%$'\n'*}
[[ ${#detail} -le 1024 ]]

MOCK_KUBECTL_MODE=save
: > "$calls"
RESUME_STATE_COMPLETED="redis"
RESUME_STATE_ERROR="Falha na etapa keycloak"
RESUME_STATE_DETAIL="Timeout"
resume_state_mark_step_complete keycloak-operator
saved_args=$(<"$calls")
[[ "$saved_args" == *"--from-literal=status=running"* ]]
[[ "$saved_args" == *"--from-literal=completed=redis keycloak-operator"* ]]
grep -qx -- '--from-literal=error=' "$calls"
grep -qx -- '--from-literal=detail=' "$calls"
[[ -z "$RESUME_STATE_ERROR" ]]
[[ -z "$RESUME_STATE_DETAIL" ]]

printf 'resume-state tests passed\n'
