#!/usr/bin/env bash
# Tela Update — Selecao de acoes por servico Plantsuite
LAYOUT_NAME="Update Servicos"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

# Entrada esperada:
# - UPDATE_SVC_INSTALLED
# - UPDATE_SVC_DEGRADED
# - UPDATE_SVC_ABSENT
# Saida:
# - APPLY=<lista>
# - DELETE=<lista>

declare -a UPD_SVC_NAMES=(
  "alarms" "controlstations" "dashboards" "devices" "entities"
  "gateway" "mes" "notifications" "portal" "production"
  "queries" "spc" "tenants" "timeseries-buffer" "timeseries-mqtt"
  "wd" "workflows"
)

declare -a UPD_SVC_STATE=()
# Acao: 0=noop, 1=apply(update/install), 2=delete
# Regras:
# - estado absent: {0,1}
# - estado installed/degraded: {0,1,2} exceto protegidos {0,1}
declare -a UPD_SVC_ACTION=()
UPD_SVC_COUNT=${#UPD_SVC_NAMES[@]}

# Servicos protegidos contra remocao por definicao de produto.
declare -a UPD_PROTECTED_REMOVE=("portal" "tenants")

list_contains_word() {
  local list="$1"
  local item="$2"
  local cur
  for cur in $list; do
    [[ "$cur" == "$item" ]] && return 0
  done
  return 1
}

is_protected_service() {
  local svc="$1"
  local p
  for p in "${UPD_PROTECTED_REMOVE[@]}"; do
    [[ "$p" == "$svc" ]] && return 0
  done
  return 1
}

load_update_services_state() {
  local i svc state
  UPD_SVC_STATE=()
  UPD_SVC_ACTION=()

  for ((i=0; i<UPD_SVC_COUNT; i++)); do
    svc="${UPD_SVC_NAMES[$i]}"

    if list_contains_word "$UPDATE_SVC_DEGRADED" "$svc"; then
      state="degraded"
    elif list_contains_word "$UPDATE_SVC_INSTALLED" "$svc"; then
      state="installed"
    else
      state="absent"
    fi

    UPD_SVC_STATE+=("$state")
    UPD_SVC_ACTION+=("0")
  done
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
    2) echo "[R ]" ;;
    *) echo "[  ]" ;;
  esac
}

set_action_for_service() {
  local idx="$1"
  local action="$2"

  local state="${UPD_SVC_STATE[$idx]}"
  local svc="${UPD_SVC_NAMES[$idx]}"

  case "$action" in
    0)
      UPD_SVC_ACTION[$idx]=0
      ;;
    1)
      UPD_SVC_ACTION[$idx]=1
      ;;
    2)
      if [[ "$state" == "absent" ]]; then
        return
      fi
      if is_protected_service "$svc"; then
        return
      fi
      UPD_SVC_ACTION[$idx]=2
      ;;
  esac
}

cycle_action_for_service() {
  local idx="$1"
  local state="${UPD_SVC_STATE[$idx]}"
  local svc="${UPD_SVC_NAMES[$idx]}"
  local cur="${UPD_SVC_ACTION[$idx]}"

  if [[ "$state" == "absent" ]]; then
    # noop -> apply -> noop
    if [[ "$cur" -eq 0 ]]; then
      UPD_SVC_ACTION[$idx]=1
    else
      UPD_SVC_ACTION[$idx]=0
    fi
    return
  fi

  if is_protected_service "$svc"; then
    # noop -> apply -> noop
    if [[ "$cur" -eq 0 ]]; then
      UPD_SVC_ACTION[$idx]=1
    else
      UPD_SVC_ACTION[$idx]=0
    fi
    return
  fi

  # instalado/degradado e removivel: noop -> apply -> delete -> noop
  case "$cur" in
    0) UPD_SVC_ACTION[$idx]=1 ;;
    1) UPD_SVC_ACTION[$idx]=2 ;;
    *) UPD_SVC_ACTION[$idx]=0 ;;
  esac
}

selected_apply_services() {
  local out="" i
  for ((i=0; i<UPD_SVC_COUNT; i++)); do
    if [[ "${UPD_SVC_ACTION[$i]}" -eq 1 ]]; then
      [[ -z "$out" ]] && out="${UPD_SVC_NAMES[$i]}" || out+=" ${UPD_SVC_NAMES[$i]}"
    fi
  done
  echo "$out"
}

selected_delete_services() {
  local out="" i
  for ((i=0; i<UPD_SVC_COUNT; i++)); do
    if [[ "${UPD_SVC_ACTION[$i]}" -eq 2 ]]; then
      [[ -z "$out" ]] && out="${UPD_SVC_NAMES[$i]}" || out+=" ${UPD_SVC_NAMES[$i]}"
    fi
  done
  echo "$out"
}

count_services_action() {
  local target="$1"
  local n=0 i
  for ((i=0; i<UPD_SVC_COUNT; i++)); do
    [[ "${UPD_SVC_ACTION[$i]}" -eq "$target" ]] && ((n++))
  done
  echo "$n"
}

draw_update_services_screen() {
  local sel="$1"

  draw_header

  local tbl_top=$((HEADER_HEIGHT + 1))
  local tbl_h=$((TUI_LINES - tbl_top - 5))
  [[ $tbl_h -lt 8 ]] && tbl_h=8

  draw_box "$tbl_top" 1 "$tbl_h" "$((TUI_COLS-2))" "Servicos PlantSuite (Atualizacao)"
  at "$((tbl_top+1))" 2 "Escolha por servico: atualizar/instalar ou remover" "$C_ACCENT"

  tput cup "$((tbl_top+2))" 2 2>/dev/null || true
  printf '%s%*s%s' "$C_DIM" "$((TUI_COLS-4))" '' "$C_RESET" | tr ' ' '-'

  local cap=$((tbl_h - 4))
  local start
  start=$(scroll_top "$UPD_SVC_COUNT" "$sel" "$cap")

  local i=0 idx st ac svc line attr col
  while [[ $i -lt $cap && $((i+start)) -lt $UPD_SVC_COUNT ]]; do
    idx=$((i+start))
    st=$(state_badge "${UPD_SVC_STATE[$idx]}")
    ac=$(action_badge "${UPD_SVC_ACTION[$idx]}")
    svc="${UPD_SVC_NAMES[$idx]}"
    line=" ${st} ${ac} ${svc}"

    clear_area "$((tbl_top+3+i))" 2 "$((TUI_COLS-4))"

    if [[ $idx -eq $sel ]]; then
      attr="$C_SELECTED"
      at "$((tbl_top+3+i))" 2 "$(trunc "$line" $((TUI_COLS-4)))" "$attr"
    else
      col="$C_DIM"
      [[ "${UPD_SVC_STATE[$idx]}" == "degraded" ]] && col="$C_WARN"
      [[ "${UPD_SVC_ACTION[$idx]}" -eq 2 ]] && col="$C_ERROR"
      at "$((tbl_top+3+i))" 2 "$(trunc "$line" $((TUI_COLS-4)))" "$col"
    fi

    ((i++)) || true
  done

  local apply_count delete_count
  apply_count=$(count_services_action 1)
  delete_count=$(count_services_action 2)

  local status="  [OK] instalado  [--] ausente  [!!] degradado  |  [U] instalar/atualizar: ${apply_count}  [R] remover: ${delete_count}"
  at "$((tbl_top+tbl_h))" 0 "$(trunc "$status" $((TUI_COLS-2)))" "$C_DIM"

  tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
  tput el 2>/dev/null || true
  colorize_hint "  ↑↓ navegar   space alternar   u aplicar   r remover   n limpar   x limpar tudo   b voltar   enter confirmar   q sair"
}

run_screen_update_services() {
  HEADER_SUBTITLE="Modo atualizacao detectado: servicos plantsuite"
  HEADER_CTX="contexto: ${SELECTED_CONTEXT:-} | overlay: ${SELECTED_OVERLAY:-}"

  load_update_services_state

  tui_check_compat
  if [[ $TUI_PLAIN -eq 1 ]]; then
    echo ""
    echo "=== Atualizacao de Servicos PlantSuite ==="

    local i
    for ((i=0; i<UPD_SVC_COUNT; i++)); do
      printf '  %2d) %s [%s]\n' "$((i+1))" "${UPD_SVC_NAMES[$i]}" "${UPD_SVC_STATE[$i]}"
    done

    echo ""
    read -rp "Atualizar/instalar (numeros, ex 1,2,5): " apply_choice
    read -rp "Remover (numeros, ex 3,4): " delete_choice

    if [[ "$apply_choice" =~ ^[qQ]$ || "$delete_choice" =~ ^[qQ]$ ]]; then
      [[ -n "${RESULT_FILE:-}" ]] && echo "__QUIT__" > "$RESULT_FILE" || echo "__QUIT__"
      return
    fi

    if [[ "$apply_choice" =~ ^[bB]$ || "$delete_choice" =~ ^[bB]$ ]]; then
      [[ -n "${RESULT_FILE:-}" ]] && echo "__BACK__" > "$RESULT_FILE" || echo "__BACK__"
      return
    fi

    local c
    if [[ -n "$apply_choice" ]]; then
      IFS=',' read -ra arr_apply <<< "$apply_choice"
      for c in "${arr_apply[@]}"; do
        c="$(echo "$c" | xargs)"
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 && "$c" -le $UPD_SVC_COUNT ]]; then
          set_action_for_service $((c-1)) 1
        fi
      done
    fi

    if [[ -n "$delete_choice" ]]; then
      IFS=',' read -ra arr_delete <<< "$delete_choice"
      for c in "${arr_delete[@]}"; do
        c="$(echo "$c" | xargs)"
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 && "$c" -le $UPD_SVC_COUNT ]]; then
          set_action_for_service $((c-1)) 2
        fi
      done
    fi

    local out_apply out_delete
    out_apply=$(selected_apply_services)
    out_delete=$(selected_delete_services)

    {
      echo "APPLY=${out_apply}"
      echo "DELETE=${out_delete}"
    } > "$RESULT_FILE"
    return
  fi

  tui_init
  tui_init_colors

  local selected=0 running=1 key i
  input_flush

  while [[ $running -eq 1 ]]; do
    _tui_move_cursor 0 0
    draw_update_services_screen "$selected"
    _tui_move_cursor 0 0

    key=$(read_key) || continue
    case "$key" in
      RESIZE)
        tui_on_resize
        ;;
      UP) selected=$(( (selected - 1 + UPD_SVC_COUNT) % UPD_SVC_COUNT )) ;;
      DOWN) selected=$(( (selected + 1) % UPD_SVC_COUNT )) ;;
      SPACE) cycle_action_for_service "$selected" ;;
      u|U) set_action_for_service "$selected" 1 ;;
      r|R) set_action_for_service "$selected" 2 ;;
      n|N) set_action_for_service "$selected" 0 ;;
      x|X)
        for ((i=0; i<UPD_SVC_COUNT; i++)); do
          UPD_SVC_ACTION[$i]=0
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

  local out_apply out_delete
  out_apply=$(selected_apply_services)
  out_delete=$(selected_delete_services)

  {
    echo "APPLY=${out_apply}"
    echo "DELETE=${out_delete}"
  } > "$RESULT_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_screen_update_services
fi
