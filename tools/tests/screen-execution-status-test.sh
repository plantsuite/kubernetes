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

printf 'screen execution status tests passed\n'
