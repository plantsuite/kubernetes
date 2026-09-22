#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/screen-execution-real.sh"

REAL_STATUS_DETAIL_CACHE_FILE=$(mktemp)
trap 'rm -f "$REAL_STATUS_DETAIL_CACHE_FILE"' EXIT

real_set_status_detail "Etapa gateway concluída"
[[ "$REAL_CURRENT_DETAIL" == "Etapa gateway concluída" ]]
[[ "$(real_detail_cache_read)" == "Etapa gateway concluída" ]]

REAL_TUI_RUNNING=0
real_execution_status_hook "Evento k8s: novo serviço"
[[ "$REAL_CURRENT_DETAIL" == "Evento k8s: novo serviço" ]]
[[ "$(real_detail_cache_read)" == "Evento k8s: novo serviço" ]]

detail="Pré-requisitos inválidos: certificado de licença inválido; dockerconfig ACR sem auth."
mapfile -t detail_lines < <(wrap_result_detail "$detail" 32)
[[ ${#detail_lines[@]} -gt 1 ]]
[[ "${detail_lines[*]}" == "$detail" ]]
for detail_line in "${detail_lines[@]}"; do
  [[ ${#detail_line} -le 32 ]]
done

REAL_EXEC_RESULT="failed"
REAL_EXEC_ERROR="Falha na etapa keycloak"
RESUME_STATE_ERROR="Falha na etapa keycloak"
RESUME_STATE_DETAIL="Timeout aguardando keycloak-operator"
real_clear_step_failure
[[ "$REAL_EXEC_RESULT" == "success" ]]
[[ -z "$REAL_EXEC_ERROR" ]]
[[ -z "$RESUME_STATE_ERROR" ]]
[[ -z "$RESUME_STATE_DETAIL" ]]

printf 'screen execution status tests passed\n'
