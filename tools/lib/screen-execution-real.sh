#!/usr/bin/env bash
# tools/lib/screen-execution-real.sh
# Tela de execução da instalação.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

declare -a REAL_STEP_STATUS=()
REAL_EXEC_RESULT="success"
REAL_EXEC_ERROR=""
REAL_CURRENT_DETAIL=""
REAL_TUI_RUNNING=0
REAL_CURRENT_STEP_INDEX=0
REAL_COMPLETED_STEPS=0
REAL_TOTAL_STEPS=0
REAL_EXEC_LOG_FILE=""
REAL_ACTIVITY_SPINNER_PID=""
REAL_LAST_LOG_LINE_CACHE_FILE=""
REAL_STATUS_DETAIL_CACHE_FILE=""

real_status_label() {
  case "$1" in
    pending) echo "[ ]" ;;
    running) echo "[>]" ;;
    success) echo "[OK]" ;;
    failed) echo "[ERRO]" ;;
    canceled) echo "[CANCELADO]" ;;
    *) echo "[?]" ;;
  esac
}

# Salvar/recuperar cache em arquivo compartilhado entre processos
real_cache_read() {
  [[ -f "${REAL_LAST_LOG_LINE_CACHE_FILE:-}" ]] && cat "$REAL_LAST_LOG_LINE_CACHE_FILE" 2>/dev/null || true
}

real_cache_write() {
  local value="$1"
  [[ -n "${REAL_LAST_LOG_LINE_CACHE_FILE:-}" ]] && printf '%s' "$value" > "$REAL_LAST_LOG_LINE_CACHE_FILE" 2>/dev/null || true
}

real_detail_cache_read() {
  [[ -f "${REAL_STATUS_DETAIL_CACHE_FILE:-}" ]] && cat "$REAL_STATUS_DETAIL_CACHE_FILE" 2>/dev/null || true
}

real_detail_cache_write() {
  local value="$1"
  [[ -n "${REAL_STATUS_DETAIL_CACHE_FILE:-}" ]] && printf '%s' "$value" > "$REAL_STATUS_DETAIL_CACHE_FILE" 2>/dev/null || true
}

real_status_color() {
  case "$1" in
    running) echo "$C_ACCENT" ;;
    success) echo "$C_TITLE" ;;
    failed|canceled) echo "$C_WARN" ;;
    *) echo "$C_DIM" ;;
  esac
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


draw_progress_bar() {
  local row="$1"
  local col="$2"
  local width="$3"
  local percent="$4"
  local filled=$((percent * width / 100))
  local empty=$((width - filled))

  tput cup "$row" "$col" 2>/dev/null || true
  printf '%s[' "$C_DIM"
  printf '%s' "$C_ACCENT"
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%s' "$C_DIM"
  printf '%*s' "$empty" '' | tr ' ' '-'
  printf ']%s' "$C_RESET"
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


draw_real_execution_chrome() {
  draw_header
  local top=$((HEADER_HEIGHT + 1))
  local h=$((TUI_LINES - top - 3))
  [[ $h -lt 10 ]] && h=10
  local op_label="Instalacao Kubernetes"
  [[ "${UPDATE_MODE:-false}" == "true" ]] && op_label="Atualizacao Kubernetes"
  draw_box "$top" 1 "$h" "$((TUI_COLS-2))" "$op_label"
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


draw_real_execution_screen() {
  local completed="$1"
  local current_idx="$2"
  local detail="$3"
  local mode="${4:-running}"

  local top=$((HEADER_HEIGHT + 1))
  local h=$((TUI_LINES - top - 3))
  local row=$((top + 2))
  local percent=$(( completed * 100 / REAL_STEP_COUNT ))
  local content_w=$((TUI_COLS - 8))

  clear_area "$row" 3 "$((TUI_COLS-8))"
  at "$row" 3 "Progresso: ${percent}% (${completed}/${REAL_STEP_COUNT} etapas concluídas)" "$C_DIM"
  ((row++))
  clear_area "$row" 3 "$((TUI_COLS-8))"
  draw_progress_bar "$row" 3 "$((TUI_COLS-8))" "$percent"
  ((row+=2))

  local cap=$((top + h - row - 2))
  [[ $cap -lt 3 ]] && cap=3
  local start
  start=$(scroll_top "$REAL_STEP_COUNT" "$current_idx" "$cap")

  local i=0 idx st line col
  while [[ $i -lt $cap && $((i+start)) -lt $REAL_STEP_COUNT ]]; do
    idx=$((i+start))
    st="${REAL_STEP_STATUS[$idx]}"
    line="$(real_status_label "$st") ${REAL_STEP_LABELS[$idx]}"
    col="$(real_status_color "$st")"
    clear_area "$((row+i))" 5 "$((TUI_COLS-10))"
    at "$((row+i))" 5 "$(trunc "$line" $((TUI_COLS-10)))" "$col"
    ((i++)) || true
  done

  if [[ "$mode" == "failure" && -n "$detail" ]]; then
    local footer_row=$((TUI_LINES - 2))
    clear_area "$footer_row" 3 "$((TUI_COLS-8))"
    at "$footer_row" 3 "$(trunc "$detail" $((TUI_COLS-8)))" "$C_WARN"
  fi

  tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
  tput el 2>/dev/null || true
  if [[ "$mode" == "failure" ]]; then
    colorize_hint "  r tentar novamente etapa   c cancelar instalação"
  fi
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


real_last_log_line() {
  # Procura pela última linha NÃO-VAZIA e legível do log.
  # Ignora linhas apenas com control characters ou espaços.
  if [[ -z "${REAL_EXEC_LOG_FILE:-}" || ! -s "$REAL_EXEC_LOG_FILE" ]]; then
    return 1
  fi

  local line
  local max_attempts=15
  local attempt=0

  # Tenta as últimas 15 linhas até encontrar uma legível.
  while (( attempt < max_attempts )); do
    line=$(tail -n $((max_attempts - attempt)) "$REAL_EXEC_LOG_FILE" 2>/dev/null | head -n 1 || true)

    # Remove quebras/caracteres de controle e sequencias ANSI.
    line="${line//$'\r'/ }"
    line="${line//$'\t'/ }"
    line=$(printf '%s' "$line" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' 2>/dev/null || printf '%s' "$line")
    line=$(printf '%s' "$line" | tr -cd '[:print:] ')

    # Se achou linha legível, cache e retorna.
    if [[ -n "$line" ]]; then
      real_cache_write "$line"
      printf '%s' "$line"
      return 0
    fi

    ((attempt++))
  done

  return 1
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


render_status_footer() {
  # Renderiza status no rodapé (linha penúltima)
  local line

  # 1. Tentar pegar do cache de detail (mais recente e confiável)
  line=$(real_detail_cache_read || true)
  
  # 2. Se não houver, tentar última linha do log
  [[ -z "$line" ]] && line=$(real_last_log_line || true)
  
  # 3. Se não houver, tentar cache de linha de log
  [[ -z "$line" ]] && line=$(real_cache_read || true)
  
  # 4. Fallback final: mensagem genérica
  if [[ -z "$line" ]]; then
    if [[ -n "${REAL_STEP_LABELS[$REAL_CURRENT_STEP_INDEX]:-}" ]]; then
      line="Executando ${REAL_STEP_LABELS[$REAL_CURRENT_STEP_INDEX]}..."
    else
      line="Aguardando conclusão..."
    fi
  fi

  local footer_row=$((TUI_LINES - 2))
  local status_w=$((TUI_COLS / 2 - 4))
  clear_area "$footer_row" 3 "$((TUI_COLS-8))"
  at "$footer_row" 3 "$(trunc "$line" "$status_w")" "$C_DIM"
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


start_real_activity_spinner() {
  stop_real_activity_spinner

  (
    local frames='|/-\\'
    local i=0
    while true; do
      local ch="${frames:i%4:1}"
      
      # Ler status atual
      local status=$(real_detail_cache_read || true)
      [[ -z "$status" ]] && status=$(real_last_log_line || true)
      [[ -z "$status" ]] && status=$(real_cache_read || true)
      [[ -z "$status" ]] && status="Aguardando..."
      
      # Calcular espaço disponível para status
      local status_max_w=$((TUI_COLS - 6))
      if [[ ${#status} -gt $status_max_w ]]; then
        status="${status:0:$status_max_w}"
      fi
      
      # Limpar e renderizar: status + spinner
      tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
      tput el 2>/dev/null || true
      printf '%s%s%s' "$C_ACCENT" "  $status " "$C_RESET"
      
      tput cup "$((TUI_LINES - 1))" "$((TUI_COLS - 3))" 2>/dev/null || true
      printf '%s%s%s' "$C_ACCENT" "$ch" "$C_RESET"
      
      i=$((i + 1))
      sleep 0.2
    done
  ) &

  REAL_ACTIVITY_SPINNER_PID="$!"
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


stop_real_activity_spinner() {
  if [[ -n "${REAL_ACTIVITY_SPINNER_PID:-}" ]]; then
    kill "$REAL_ACTIVITY_SPINNER_PID" >/dev/null 2>&1 || true
    wait "$REAL_ACTIVITY_SPINNER_PID" 2>/dev/null || true
    REAL_ACTIVITY_SPINNER_PID=""
  fi

  tput cup "$((TUI_LINES - 1))" "$((TUI_COLS - 3))" 2>/dev/null || true
  printf ' '
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


render_execution_real_progress_only() {
  draw_real_execution_screen "$REAL_COMPLETED_STEPS" "$REAL_CURRENT_STEP_INDEX" "$REAL_CURRENT_DETAIL" "running"
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


real_execution_status_hook() {
  local detail="$1"
  REAL_CURRENT_DETAIL="$detail"
  real_detail_cache_write "$detail"
  if [[ ${REAL_TUI_RUNNING:-0} -eq 1 ]]; then
    render_execution_real_progress_only
  fi
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


draw_real_result_screen() {
  local top=$((HEADER_HEIGHT + 1))
  local h=$((TUI_LINES - top - 3))
  local result_title="Resumo da Instalacao"
  [[ "${UPDATE_MODE:-false}" == "true" ]] && result_title="Resumo da Atualizacao"
  draw_box "$top" 1 "$h" "$((TUI_COLS-2))" "$result_title"

  # Limpa a área interna da caixa para evitar sobreposição com a tela anterior.
  local clear_row
  for ((clear_row=top+1; clear_row<top+h-1; clear_row++)); do
    clear_area "$clear_row" 3 "$((TUI_COLS-8))"
  done

  local row=$((top + 2))
  if [[ "$REAL_EXEC_RESULT" == "success" ]]; then
    if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
      at "$row" 3 "Atualizacao finalizada com sucesso." "$C_TITLE"
    else
      at "$row" 3 "Instalacao finalizada com sucesso." "$C_TITLE"
    fi
  elif [[ "$REAL_EXEC_RESULT" == "canceled" ]]; then
    if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
      at "$row" 3 "Atualizacao cancelada pelo usuario." "$C_WARN"
    else
      at "$row" 3 "Instalacao cancelada pelo usuario." "$C_WARN"
    fi
  else
    if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
      at "$row" 3 "Atualizacao finalizada com erro." "$C_WARN"
    else
      at "$row" 3 "Instalacao finalizada com erro." "$C_WARN"
    fi
  fi
  ((row+=2))

  if [[ -n "$REAL_EXEC_ERROR" ]]; then
    at "$row" 3 "Detalhe: $(trunc "$REAL_EXEC_ERROR" $((TUI_COLS-12)))" "$C_DIM"
    ((row++))
  fi

  tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
  tput el 2>/dev/null || true
  colorize_hint "  enter sair"
}

# Salvar/recuperar cache em arquivo compartilhado entre processos


run_screen_execution_real() {
  if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
    HEADER_SUBTITLE="Executando atualizacao"
    build_update_pipeline
  else
    HEADER_SUBTITLE="Executando instalacao"
    build_real_pipeline
  fi
  HEADER_CTX="contexto: ${SELECTED_CONTEXT:-} | overlay: ${SELECTED_OVERLAY:-}"

  local i
  REAL_STEP_STATUS=()
  for ((i=0; i<REAL_STEP_COUNT; i++)); do
    REAL_STEP_STATUS+=("pending")
  done

  # Fallback plain
  tui_check_compat
  if [[ $TUI_PLAIN -eq 1 ]]; then
    echo ""
    if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
      echo "=== Atualizacao Kubernetes ==="
    else
      echo "=== Instalacao Kubernetes ==="
    fi
    echo "Contexto/Overlay: $HEADER_CTX"

    if ! real_assert_prereqs; then
      echo "[ERRO] $REAL_LAST_ERROR"
      [[ -n "${RESULT_FILE:-}" ]] && echo "failed" > "$RESULT_FILE" || echo "failed"
      return
    fi

    for ((i=0; i<REAL_STEP_COUNT; i++)); do
      echo "[>] ${REAL_STEP_LABELS[$i]}"
      if ! real_execute_step "${REAL_STEP_IDS[$i]}"; then
        echo "[ERRO] ${REAL_STEP_LABELS[$i]}"
        echo "$REAL_LAST_ERROR"
        [[ -n "${RESULT_FILE:-}" ]] && echo "failed" > "$RESULT_FILE" || echo "failed"
        return
      fi
      echo "[OK] ${REAL_STEP_LABELS[$i]}"
    done

    [[ -n "${RESULT_FILE:-}" ]] && echo "success" > "$RESULT_FILE" || echo "success"
    return
  fi

  tui_init
  tui_init_colors
  tput clear 2>/dev/null || true
  draw_real_execution_chrome

  # Captura logs verbosos da execução real na pasta atual da execução.
  REAL_EXEC_LOG_FILE="$PWD/install-$(date +%Y%m%d-%H%M%S).log"
  : > "$REAL_EXEC_LOG_FILE"

  # Inicializar cache compartilhado para linhas de log entre processos
  REAL_LAST_LOG_LINE_CACHE_FILE=$(mktemp)
  REAL_STATUS_DETAIL_CACHE_FILE=$(mktemp)
  trap 'rm -f "$REAL_LAST_LOG_LINE_CACHE_FILE" "$REAL_STATUS_DETAIL_CACHE_FILE"' RETURN

  if ! real_assert_prereqs; then
    REAL_EXEC_RESULT="failed"
    REAL_EXEC_ERROR="$REAL_LAST_ERROR"
  else
    local completed=0
    REAL_TOTAL_STEPS="$REAL_STEP_COUNT"
    REAL_TUI_RUNNING=1
    REAL_STATUS_HOOK="real_execution_status_hook"
    for ((i=0; i<REAL_STEP_COUNT; i++)); do
      REAL_STEP_STATUS[$i]="running"
      REAL_CURRENT_STEP_INDEX="$i"
      REAL_COMPLETED_STEPS="$completed"
      REAL_CURRENT_DETAIL="Iniciando ${REAL_STEP_LABELS[$i]}..."
      draw_real_execution_screen "$completed" "$i" "$REAL_CURRENT_DETAIL"
      start_real_activity_spinner

        if ! real_execute_step "${REAL_STEP_IDS[$i]}" >>"$REAL_EXEC_LOG_FILE" 2>&1; then
        stop_real_activity_spinner
        REAL_TUI_RUNNING=0
        REAL_STATUS_HOOK=""
        REAL_STEP_STATUS[$i]="failed"
        REAL_EXEC_RESULT="failed"
        REAL_EXEC_ERROR="${REAL_LAST_ERROR:-${REAL_LAST_DETAIL:-Falha na etapa ${REAL_STEP_LABELS[$i]}}}"
        input_flush
        local failure_detail="${REAL_LAST_DETAIL:-$REAL_LAST_ERROR}"
        while true; do
          draw_real_execution_screen "$completed" "$i" "$failure_detail" "failure"
          local key
          key=$(read_key) || continue
          case "$key" in
            r|R)
              REAL_STEP_STATUS[$i]="running"
              REAL_TUI_RUNNING=1
              REAL_STATUS_HOOK="real_execution_status_hook"
              REAL_CURRENT_STEP_INDEX="$i"
              REAL_COMPLETED_STEPS="$completed"
              REAL_CURRENT_DETAIL="Reexecutando ${REAL_STEP_LABELS[$i]}..."
              start_real_activity_spinner
                if real_execute_step "${REAL_STEP_IDS[$i]}" >>"$REAL_EXEC_LOG_FILE" 2>&1; then
                stop_real_activity_spinner
                REAL_TUI_RUNNING=0
                REAL_STATUS_HOOK=""
                REAL_STEP_STATUS[$i]="success"
                completed=$((completed + 1))
                break
              fi
              stop_real_activity_spinner
              REAL_TUI_RUNNING=0
              REAL_STATUS_HOOK=""
              REAL_STEP_STATUS[$i]="failed"
              REAL_EXEC_ERROR="${REAL_LAST_ERROR:-${REAL_LAST_DETAIL:-Falha na etapa ${REAL_STEP_LABELS[$i]}}}"
              failure_detail="${REAL_LAST_DETAIL:-$REAL_LAST_ERROR}"
              ;;
            c|C)
              REAL_STEP_STATUS[$i]="canceled"
              REAL_EXEC_RESULT="canceled"
              stop_real_activity_spinner
              break 2
              ;;
          esac
        done
      else
        stop_real_activity_spinner
        REAL_STEP_STATUS[$i]="success"
        completed=$((completed + 1))
      fi

      REAL_COMPLETED_STEPS="$completed"
      draw_real_execution_screen "$completed" "$i" "Etapa concluída"
    done

    stop_real_activity_spinner
    REAL_TUI_RUNNING=0
    REAL_STATUS_HOOK=""

    if [[ "$REAL_EXEC_RESULT" == "success" ]]; then
      REAL_EXEC_ERROR=""
    fi
  fi

  draw_real_result_screen

  # Renderizar informações de log no rodapé
  tput cup "$((TUI_LINES - 2))" 3 2>/dev/null || true
  tput el 2>/dev/null || true
  at "$((TUI_LINES - 2))" 3 "Log técnico: $(trunc "$REAL_EXEC_LOG_FILE" $((TUI_COLS/2-10)))" "$C_DIM"

  input_flush
  local k
  while true; do
    k=$(read_key) || k="ENTER"
    [[ "$k" == "ENTER" ]] && break
  done

  _tui_cleanup
  trap - EXIT INT TERM WINCH

  if [[ -n "${RESULT_FILE:-}" ]]; then
    echo "$REAL_EXEC_RESULT" > "$RESULT_FILE"
  else
    echo "$REAL_EXEC_RESULT"
  fi
}

# Salvar/recuperar cache em arquivo compartilhado entre processos

