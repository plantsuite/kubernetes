#!/usr/bin/env bash
# Tela Update — Selecao de infraestrutura para reaplicar atualizacao
LAYOUT_NAME="Update Infra"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

# Entrada esperada:
# - UPDATE_INFRA_INSTALLED
# - UPDATE_INFRA_DEGRADED
# - UPDATE_INFRA_ABSENT

declare -a UPD_INFRA_NAMES=()
declare -a UPD_INFRA_STATE=()
declare -a UPD_INFRA_ACTION=() # 0=noop 1=apply
UPD_INFRA_COUNT=0

list_contains_word() {
  local list="$1"
  local item="$2"
  local cur
  for cur in $list; do
    [[ "$cur" == "$item" ]] && return 0
  done
  return 1
}

load_update_infra_state() {
  UPD_INFRA_NAMES=()
  UPD_INFRA_STATE=()
  UPD_INFRA_ACTION=()

  local component state
  for component in "${INFRA_COMPONENTS[@]}"; do
    if list_contains_word "$UPDATE_INFRA_DEGRADED" "$component"; then
      state="degraded"
    elif list_contains_word "$UPDATE_INFRA_INSTALLED" "$component"; then
      state="installed"
    else
      state="absent"
    fi

    UPD_INFRA_NAMES+=("$component")
    UPD_INFRA_STATE+=("$state")
    UPD_INFRA_ACTION+=("0")
  done

  UPD_INFRA_COUNT=${#UPD_INFRA_NAMES[@]}
}

state_badge() {
  case "$1" in
    installed) echo "[OK]" ;;
    degraded) echo "[!!]" ;;
    *) echo "[--]" ;;
  esac
}

action_badge() {
  case "$1" in
    1) echo "[U ]" ;;
    *) echo "[  ]" ;;
  esac
}

toggle_infra_action() {
  local idx="$1"
  [[ $idx -lt 0 || $idx -ge $UPD_INFRA_COUNT ]] && return
  if [[ "${UPD_INFRA_ACTION[$idx]}" -eq 1 ]]; then
    UPD_INFRA_ACTION[$idx]=0
  else
    UPD_INFRA_ACTION[$idx]=1
  fi
}

selected_infra_list() {
  local out=""
  local i
  for ((i=0; i<UPD_INFRA_COUNT; i++)); do
    if [[ "${UPD_INFRA_ACTION[$i]}" -eq 1 ]]; then
      if [[ -z "$out" ]]; then
        out="${UPD_INFRA_NAMES[$i]}"
      else
        out+=" ${UPD_INFRA_NAMES[$i]}"
      fi
    fi
  done
  echo "$out"
}

count_selected_infra() {
  local n=0 i
  for ((i=0; i<UPD_INFRA_COUNT; i++)); do
    [[ "${UPD_INFRA_ACTION[$i]}" -eq 1 ]] && ((n++))
  done
  echo "$n"
}

draw_update_infra_screen() {
  local sel="$1"

  draw_header

  local tbl_top=$((HEADER_HEIGHT + 1))
  local tbl_h=$((TUI_LINES - tbl_top - 5))
  [[ $tbl_h -lt 8 ]] && tbl_h=8

  draw_box "$tbl_top" 1 "$tbl_h" "$((TUI_COLS-2))" "Infraestrutura (Atualizacao)"
  at "$((tbl_top+1))" 2 "Selecione os componentes que deseja reaplicar" "$C_ACCENT"

  tput cup "$((tbl_top+2))" 2 2>/dev/null || true
  printf '%s%*s%s' "$C_DIM" "$((TUI_COLS-4))" '' "$C_RESET" | tr ' ' '-'

  local cap=$((tbl_h - 4))
  local start
  start=$(scroll_top "$UPD_INFRA_COUNT" "$sel" "$cap")

  local i=0 idx line attr st ac col
  while [[ $i -lt $cap && $((i+start)) -lt $UPD_INFRA_COUNT ]]; do
    idx=$((i+start))
    st=$(state_badge "${UPD_INFRA_STATE[$idx]}")
    ac=$(action_badge "${UPD_INFRA_ACTION[$idx]}")
    line=" ${st} ${ac} ${UPD_INFRA_NAMES[$idx]}"

    if [[ $idx -eq $sel ]]; then
      attr="$C_SELECTED"
    else
      attr=""
    fi

    clear_area "$((tbl_top+3+i))" 2 "$((TUI_COLS-4))"
    if [[ -n "$attr" ]]; then
      at "$((tbl_top+3+i))" 2 "$(trunc "$line" $((TUI_COLS-4)))" "$attr"
    else
      col="$C_DIM"
      [[ "${UPD_INFRA_STATE[$idx]}" == "degraded" ]] && col="$C_WARN"
      at "$((tbl_top+3+i))" 2 "$(trunc "$line" $((TUI_COLS-4)))" "$col"
    fi

    ((i++)) || true
  done

  local selected_count
  selected_count=$(count_selected_infra)
  local status="  [OK] instalado  [--] ausente  [!!] degradado   |   Marcados para atualizar: ${selected_count}/${UPD_INFRA_COUNT}"
  at "$((tbl_top+tbl_h))" 0 "$(trunc "$status" $((TUI_COLS-2)))" "$C_DIM"

  tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
  tput el 2>/dev/null || true
  colorize_hint "  ↑↓ navegar   space marcar   x limpar   b voltar   enter confirmar   q sair"
}

run_screen_update_infra() {
  HEADER_SUBTITLE="Modo atualizacao detectado: selecione a infraestrutura"
  HEADER_CTX="contexto: ${SELECTED_CONTEXT:-} | overlay: ${SELECTED_OVERLAY:-}"

  load_update_infra_state

  tui_check_compat
  if [[ $TUI_PLAIN -eq 1 ]]; then
    echo ""
    echo "=== Atualizacao de Infraestrutura ==="
    local i
    for ((i=0; i<UPD_INFRA_COUNT; i++)); do
      printf '  %2d) %s [%s]\n' "$((i+1))" "${UPD_INFRA_NAMES[$i]}" "${UPD_INFRA_STATE[$i]}"
    done
    echo ""
    read -rp "Digite os numeros para atualizar (ex: 1,3,5), B para voltar, Q para sair: " choice

    if [[ "$choice" =~ ^[qQ]$ ]]; then
      [[ -n "${RESULT_FILE:-}" ]] && echo "__QUIT__" > "$RESULT_FILE" || echo "__QUIT__"
      return
    fi

    if [[ "$choice" =~ ^[bB]$ ]]; then
      [[ -n "${RESULT_FILE:-}" ]] && echo "__BACK__" > "$RESULT_FILE" || echo "__BACK__"
      return
    fi

    if [[ -n "$choice" ]]; then
      IFS=',' read -ra arr <<< "$choice"
      local c
      for c in "${arr[@]}"; do
        c="$(echo "$c" | xargs)"
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 && "$c" -le $UPD_INFRA_COUNT ]]; then
          UPD_INFRA_ACTION[$((c-1))]=1
        fi
      done
    fi

    local result
    result=$(selected_infra_list)
    [[ -n "${RESULT_FILE:-}" ]] && echo "$result" > "$RESULT_FILE" || echo "$result"
    return
  fi

  tui_init
  tui_init_colors

  local selected=0 key running=1 i
  input_flush

  while [[ $running -eq 1 ]]; do
    _tui_move_cursor 0 0
    draw_update_infra_screen "$selected"
    _tui_move_cursor 0 0

    key=$(read_key) || continue
    case "$key" in
      RESIZE)
        tui_on_resize
        ;;
      UP) selected=$(( (selected - 1 + UPD_INFRA_COUNT) % UPD_INFRA_COUNT )) ;;
      DOWN) selected=$(( (selected + 1) % UPD_INFRA_COUNT )) ;;
      SPACE) toggle_infra_action "$selected" ;;
      x|X)
        for ((i=0; i<UPD_INFRA_COUNT; i++)); do
          UPD_INFRA_ACTION[$i]=0
        done
        ;;
      ENTER) running=0 ;;
      b) running=0; key="BACK" ;;
      QUIT|ESC) running=0; key="QUIT" ;;
    esac
  done

  _tui_cleanup
  trap - EXIT INT TERM WINCH

  if [[ "$key" == "QUIT" ]]; then
    [[ -n "${RESULT_FILE:-}" ]] && echo "__QUIT__" > "$RESULT_FILE" || echo "__QUIT__"
    return
  fi

  if [[ "$key" == "BACK" ]]; then
    [[ -n "${RESULT_FILE:-}" ]] && echo "__BACK__" > "$RESULT_FILE" || echo "__BACK__"
    return
  fi

  local result
  result=$(selected_infra_list)
  [[ -n "${RESULT_FILE:-}" ]] && echo "$result" > "$RESULT_FILE" || echo "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_screen_update_infra
fi
