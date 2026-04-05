#!/usr/bin/env bash
# Tela Update — Seleção unificada de Infra + Serviços PlantSuite
LAYOUT_NAME="Update Seleção"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

# Entradas esperadas:
# - UPDATE_INFRA_INSTALLED
# - UPDATE_INFRA_DEGRADED
# - UPDATE_INFRA_ABSENT
# - UPDATE_SVC_INSTALLED
# - UPDATE_SVC_DEGRADED
# - UPDATE_SVC_ABSENT

# Saida em RESULT_FILE:
# APPLY_INFRA=<lista>
# APPLY_SERVICES=<lista>
# DELETE_SERVICES=<lista>

declare -a UPD_INFRA_NAMES=()
declare -a UPD_INFRA_STATE=()
declare -a UPD_INFRA_ACTION=() # 0=noop, 1=apply
UPD_INFRA_COUNT=0

declare -a UPD_SVC_NAMES=(
  "alarms" "controlstation" "dashboards" "devices" "entities"
  "gateway" "mes" "notifications" "portal" "production"
  "queries" "spc" "tenants" "timeseries-buffer" "timeseries-mqtt"
  "wd" "workflows"
)
declare -a UPD_SVC_STATE=()
declare -a UPD_SVC_ACTION=() # 0=noop, 1=apply, 2=delete
UPD_SVC_COUNT=${#UPD_SVC_NAMES[@]}

declare -a UPD_PROTECTED_REMOVE=("portal" "tenants")

# Mapa de linhas selecionaveis da lista unificada.
# Cada entrada: "infra:<idx>" ou "svc:<idx>"
declare -a UPD_ROWS=()
UPD_ROWS_COUNT=0

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

state_badge() {
  case "$1" in
    installed) echo "[OK]" ;;
    degraded) echo "[!!]" ;;
    *) echo "[--]" ;;
  esac
}

action_badge_infra() {
  local action="$1" state="${2:-}"
  case "$action" in
    1) [[ "$state" == "absent" ]] && echo "[I]" || echo "[U]" ;;
    *) echo "[ ]" ;;
  esac
}

action_badge_svc() {
  local action="$1" state="${2:-}"
  case "$action" in
    1) [[ "$state" == "absent" ]] && echo "[I]" || echo "[U]" ;;
    2) echo "[R]" ;;
    *) echo "[ ]" ;;
  esac
}

load_update_state() {
  local i component state svc

  UPD_INFRA_NAMES=()
  UPD_INFRA_STATE=()
  UPD_INFRA_ACTION=()

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

build_rows_map() {
  UPD_ROWS=()
  local i
  UPD_ROWS+=("blank:")
  UPD_ROWS+=("sep:INFRAESTRUTURA")
  for ((i=0; i<UPD_INFRA_COUNT; i++)); do
    UPD_ROWS+=("infra:$i")
  done
  UPD_ROWS+=("blank:")
  UPD_ROWS+=("sep:PLANTSUITE")
  for ((i=0; i<UPD_SVC_COUNT; i++)); do
    UPD_ROWS+=("svc:$i")
  done
  UPD_ROWS_COUNT=${#UPD_ROWS[@]}
}

toggle_row_action() {
  local row_idx="$1"
  local row="${UPD_ROWS[$row_idx]}"
  local row_type="${row%%:*}"
  [[ "$row_type" == "sep" || "$row_type" == "blank" ]] && return
  local idx="${row#*:}"

  if [[ "$row_type" == "infra" ]]; then
    if [[ "${UPD_INFRA_ACTION[$idx]}" -eq 1 ]]; then
      UPD_INFRA_ACTION[$idx]=0
    else
      UPD_INFRA_ACTION[$idx]=1
    fi
    return
  fi

  local state="${UPD_SVC_STATE[$idx]}"
  local svc="${UPD_SVC_NAMES[$idx]}"
  local cur="${UPD_SVC_ACTION[$idx]}"

  if [[ "$state" == "absent" ]]; then
    # noop -> apply -> noop
    [[ "$cur" -eq 0 ]] && UPD_SVC_ACTION[$idx]=1 || UPD_SVC_ACTION[$idx]=0
    return
  fi

  if is_protected_service "$svc"; then
    # noop -> apply -> noop
    [[ "$cur" -eq 0 ]] && UPD_SVC_ACTION[$idx]=1 || UPD_SVC_ACTION[$idx]=0
    return
  fi

  # installed/degraded: noop -> apply -> delete -> noop
  case "$cur" in
    0) UPD_SVC_ACTION[$idx]=1 ;;
    1) UPD_SVC_ACTION[$idx]=2 ;;
    *) UPD_SVC_ACTION[$idx]=0 ;;
  esac
}

set_row_action() {
  local row_idx="$1"
  local action="$2" # apply|delete|none
  local row="${UPD_ROWS[$row_idx]}"
  local row_type="${row%%:*}"
  [[ "$row_type" == "sep" || "$row_type" == "blank" ]] && return
  local idx="${row#*:}"

  if [[ "$row_type" == "infra" ]]; then
    case "$action" in
      apply) UPD_INFRA_ACTION[$idx]=1 ;;
      *) UPD_INFRA_ACTION[$idx]=0 ;;
    esac
    return
  fi

  local state="${UPD_SVC_STATE[$idx]}"
  local svc="${UPD_SVC_NAMES[$idx]}"
  case "$action" in
    apply)
      UPD_SVC_ACTION[$idx]=1
      ;;
    delete)
      if [[ "$state" != "absent" ]] && ! is_protected_service "$svc"; then
        UPD_SVC_ACTION[$idx]=2
      fi
      ;;
    *)
      UPD_SVC_ACTION[$idx]=0
      ;;
  esac
}

count_infra_apply() {
  local n=0 i
  for ((i=0; i<UPD_INFRA_COUNT; i++)); do
    [[ "${UPD_INFRA_ACTION[$i]}" -eq 1 ]] && ((n++))
  done
  echo "$n"
}

count_svc_apply() {
  local n=0 i
  for ((i=0; i<UPD_SVC_COUNT; i++)); do
    [[ "${UPD_SVC_ACTION[$i]}" -eq 1 ]] && ((n++))
  done
  echo "$n"
}

count_svc_delete() {
  local n=0 i
  for ((i=0; i<UPD_SVC_COUNT; i++)); do
    [[ "${UPD_SVC_ACTION[$i]}" -eq 2 ]] && ((n++))
  done
  echo "$n"
}

selected_infra_list() {
  local out="" i
  for ((i=0; i<UPD_INFRA_COUNT; i++)); do
    if [[ "${UPD_INFRA_ACTION[$i]}" -eq 1 ]]; then
      [[ -z "$out" ]] && out="${UPD_INFRA_NAMES[$i]}" || out+=" ${UPD_INFRA_NAMES[$i]}"
    fi
  done
  echo "$out"
}

selected_svc_apply_list() {
  local out="" i
  for ((i=0; i<UPD_SVC_COUNT; i++)); do
    if [[ "${UPD_SVC_ACTION[$i]}" -eq 1 ]]; then
      [[ -z "$out" ]] && out="${UPD_SVC_NAMES[$i]}" || out+=" ${UPD_SVC_NAMES[$i]}"
    fi
  done
  echo "$out"
}

selected_svc_delete_list() {
  local out="" i
  for ((i=0; i<UPD_SVC_COUNT; i++)); do
    if [[ "${UPD_SVC_ACTION[$i]}" -eq 2 ]]; then
      [[ -z "$out" ]] && out="${UPD_SVC_NAMES[$i]}" || out+=" ${UPD_SVC_NAMES[$i]}"
    fi
  done
  echo "$out"
}

draw_update_selection_screen() {
  local sel="$1"
  local msg="${2:-}"

  draw_header

  local tbl_top=$((HEADER_HEIGHT + 1))
  local tbl_h=$((TUI_LINES - tbl_top - 5))
  [[ $tbl_h -lt 10 ]] && tbl_h=10

  draw_box "$tbl_top" 1 "$tbl_h" "$((TUI_COLS-2))" "Atualização"

  local cap=$((tbl_h - 2))
  local start
  start=$(scroll_top "$UPD_ROWS_COUNT" "$sel" "$cap")

  local i=0 row_idx row row_type idx line st ac col attr svc state sep_title fill fill_len state_var item_name bc
  while [[ $i -lt $cap && $((i+start)) -lt $UPD_ROWS_COUNT ]]; do
    row_idx=$((i+start))
    row="${UPD_ROWS[$row_idx]}"
    row_type="${row%%:*}"
    idx="${row#*:}"

    clear_area "$((tbl_top+1+i))" 2 "$((TUI_COLS-4))"

    if [[ "$row_type" == "blank" ]]; then
      ((i++)) || true
      continue
    fi

    if [[ "$row_type" == "sep" ]]; then
      sep_title=" ${idx} "
      fill_len=$(( TUI_COLS - 6 - ${#sep_title} ))
      [[ $fill_len -lt 0 ]] && fill_len=0
      fill=$(printf '%*s' "$fill_len" '' | tr ' ' '-')
      tput cup "$((tbl_top+1+i))" 2 2>/dev/null || true
      printf '%s%s%s%s' "$C_ACCENT" "$sep_title" "$C_DIM" "$fill"
      printf '%s' "$C_RESET"
      ((i++)) || true
      continue
    fi

    line=""
    col="$C_DIM"

    if [[ "$row_type" == "infra" ]]; then
      state_var="${UPD_INFRA_STATE[$idx]}"
      st=$(state_badge "$state_var")
      ac=$(action_badge_infra "${UPD_INFRA_ACTION[$idx]}" "$state_var")
      item_name="${UPD_INFRA_NAMES[$idx]}"
      line="  ${st} ${ac} ${item_name}"
      [[ "$state_var" == "degraded" ]] && col="$C_WARN"
      [[ "${UPD_INFRA_ACTION[$idx]}" -eq 1 ]] && col="$C_WARN"
    else
      state="${UPD_SVC_STATE[$idx]}"
      state_var="$state"
      svc="${UPD_SVC_NAMES[$idx]}"
      item_name="$svc"
      st=$(state_badge "$state_var")
      ac=$(action_badge_svc "${UPD_SVC_ACTION[$idx]}" "$state_var")
      line="  ${st} ${ac} ${svc}"
      [[ "$state" == "degraded" ]] && col="$C_WARN"
      [[ "${UPD_SVC_ACTION[$idx]}" -eq 1 ]] && col="$C_WARN"
      [[ "${UPD_SVC_ACTION[$idx]}" -eq 2 ]] && col="$C_ERROR"
    fi

    if [[ $row_idx -eq $sel ]]; then
      at "$((tbl_top+1+i))" 2 "$(trunc "$line" $((TUI_COLS-4)))" "$C_SELECTED"
    else
      case "$state_var" in
        installed) bc="$C_SUCCESS" ;;
        degraded)  bc="$C_WARN" ;;
        *)         bc="$C_DIM" ;;
      esac
      at "$((tbl_top+1+i))" 4 "$st" "$bc"
      at "$((tbl_top+1+i))" 9 "$(trunc "${ac} ${item_name}" $((TUI_COLS-13)))" "$col"
    fi

    ((i++)) || true
  done

  local infra_apply svc_apply svc_delete
  infra_apply=$(count_infra_apply)
  svc_apply=$(count_svc_apply)
  svc_delete=$(count_svc_delete)

  tput cup "$((tbl_top+tbl_h))" 0 2>/dev/null || true
  tput el 2>/dev/null || true
  printf '%s  %s[OK]%s instalado  [--] ausente  %s[!!]%s degradado  |  [I] instalar  [U] atualizar  [R] remover  |  plantsuite(I+U)=%s  plantsuite(R)=%s%s' \
    "$C_DIM" "$C_SUCCESS" "$C_DIM" "$C_WARN" "$C_DIM" \
    "$svc_apply" "$svc_delete" "$C_RESET"

  tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
  tput el 2>/dev/null || true
  colorize_hint "  ↑↓ navegar   space alternar   u aplicar   r remover   n limpar   x limpar tudo   b voltar   enter confirmar   q sair"

  if [[ -n "$msg" ]]; then
    tput cup "$((TUI_LINES - 2))" 0 2>/dev/null || true
    tput el 2>/dev/null || true
    at "$((TUI_LINES - 2))" 2 "$msg" "$C_WARN" "$((TUI_COLS-4))"
  fi
}

draw_update_selection_row() {
  local row_idx="$1"
  local sel="$2"
  local start="$3"
  local tbl_top="$4"
  local cap="$5"

  if [[ $row_idx -lt $start || $row_idx -ge $((start + cap)) ]]; then
    return
  fi

  local i=$((row_idx - start))
  local row="${UPD_ROWS[$row_idx]}"
  local row_type="${row%%:*}"
  local idx="${row#*:}"

  clear_area "$((tbl_top+1+i))" 2 "$((TUI_COLS-4))"

  if [[ "$row_type" == "blank" ]]; then
    return
  fi

  if [[ "$row_type" == "sep" ]]; then
    local sep_title=" ${idx} " fill_len fill
    fill_len=$(( TUI_COLS - 6 - ${#sep_title} ))
    [[ $fill_len -lt 0 ]] && fill_len=0
    fill=$(printf '%*s' "$fill_len" '' | tr ' ' '-')
    tput cup "$((tbl_top+1+i))" 2 2>/dev/null || true
    printf '%s%s%s%s' "$C_ACCENT" "$sep_title" "$C_DIM" "$fill"
    printf '%s' "$C_RESET"
    return
  fi

  local line="" col="$C_DIM" st ac state_var item_name bc state svc

  if [[ "$row_type" == "infra" ]]; then
    state_var="${UPD_INFRA_STATE[$idx]}"
    st=$(state_badge "$state_var")
    ac=$(action_badge_infra "${UPD_INFRA_ACTION[$idx]}" "$state_var")
    item_name="${UPD_INFRA_NAMES[$idx]}"
    line="  ${st} ${ac} ${item_name}"
    [[ "$state_var" == "degraded" ]] && col="$C_WARN"
    [[ "${UPD_INFRA_ACTION[$idx]}" -eq 1 ]] && col="$C_WARN"
  else
    state="${UPD_SVC_STATE[$idx]}"
    state_var="$state"
    svc="${UPD_SVC_NAMES[$idx]}"
    item_name="$svc"
    st=$(state_badge "$state_var")
    ac=$(action_badge_svc "${UPD_SVC_ACTION[$idx]}" "$state_var")
    line="  ${st} ${ac} ${svc}"
    [[ "$state" == "degraded" ]] && col="$C_WARN"
    [[ "${UPD_SVC_ACTION[$idx]}" -eq 1 ]] && col="$C_WARN"
    [[ "${UPD_SVC_ACTION[$idx]}" -eq 2 ]] && col="$C_ERROR"
  fi

  if [[ $row_idx -eq $sel ]]; then
    at "$((tbl_top+1+i))" 2 "$(trunc "$line" $((TUI_COLS-4)))" "$C_SELECTED"
  else
    case "$state_var" in
      installed) bc="$C_SUCCESS" ;;
      degraded)  bc="$C_WARN" ;;
      *)         bc="$C_DIM" ;;
    esac
    at "$((tbl_top+1+i))" 4 "$st" "$bc"
    at "$((tbl_top+1+i))" 9 "$(trunc "${ac} ${item_name}" $((TUI_COLS-13)))" "$col"
  fi
}

run_screen_update_selection() {
  HEADER_SUBTITLE="Modo atualização detectado: seleção unificada"
  HEADER_CTX="contexto: ${SELECTED_CONTEXT:-} | overlay: ${SELECTED_OVERLAY:-}"

  load_update_state
  build_rows_map

  tui_check_compat
  if [[ $TUI_PLAIN -eq 1 ]]; then
    echo ""
    echo "=== Atualização Unificada (Infra + Serviços) ==="

    echo "Infraestrutura:"
    local i
    for ((i=0; i<UPD_INFRA_COUNT; i++)); do
      printf '  I%02d) %s [%s]\n' "$((i+1))" "${UPD_INFRA_NAMES[$i]}" "${UPD_INFRA_STATE[$i]}"
    done

    echo ""
    echo "Serviços PlantSuite:"
    for ((i=0; i<UPD_SVC_COUNT; i++)); do
      printf '  S%02d) %s [%s]\n' "$((i+1))" "${UPD_SVC_NAMES[$i]}" "${UPD_SVC_STATE[$i]}"
    done

    echo ""
    read -rp "Infra para aplicar (ex: 1,3,5): " infra_choice
    read -rp "Serviços para aplicar (ex: 1,2,8): " svc_apply_choice
    read -rp "Serviços para remover (ex: 4,7): " svc_delete_choice

    if [[ "$infra_choice" =~ ^[qQ]$ || "$svc_apply_choice" =~ ^[qQ]$ || "$svc_delete_choice" =~ ^[qQ]$ ]]; then
      [[ -n "${RESULT_FILE:-}" ]] && echo "__QUIT__" > "$RESULT_FILE" || echo "__QUIT__"
      return
    fi

    if [[ "$infra_choice" =~ ^[bB]$ || "$svc_apply_choice" =~ ^[bB]$ || "$svc_delete_choice" =~ ^[bB]$ ]]; then
      [[ -n "${RESULT_FILE:-}" ]] && echo "__BACK__" > "$RESULT_FILE" || echo "__BACK__"
      return
    fi

    local c
    if [[ -n "$infra_choice" ]]; then
      IFS=',' read -ra arr_infra <<< "$infra_choice"
      for c in "${arr_infra[@]}"; do
        c="$(echo "$c" | xargs)"
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 && "$c" -le $UPD_INFRA_COUNT ]]; then
          UPD_INFRA_ACTION[$((c-1))]=1
        fi
      done
    fi

    if [[ -n "$svc_apply_choice" ]]; then
      IFS=',' read -ra arr_apply <<< "$svc_apply_choice"
      for c in "${arr_apply[@]}"; do
        c="$(echo "$c" | xargs)"
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 && "$c" -le $UPD_SVC_COUNT ]]; then
          UPD_SVC_ACTION[$((c-1))]=1
        fi
      done
    fi

    if [[ -n "$svc_delete_choice" ]]; then
      IFS=',' read -ra arr_delete <<< "$svc_delete_choice"
      for c in "${arr_delete[@]}"; do
        c="$(echo "$c" | xargs)"
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 && "$c" -le $UPD_SVC_COUNT ]]; then
          if [[ "${UPD_SVC_STATE[$((c-1))]}" != "absent" ]] && ! is_protected_service "${UPD_SVC_NAMES[$((c-1))]}"; then
            UPD_SVC_ACTION[$((c-1))]=2
          fi
        fi
      done
    fi

    UPDATE_SELECTED_INFRA="$(selected_infra_list)"
    UPDATE_SELECTED_PLANTSUITE_APPLY="$(selected_svc_apply_list)"
    UPDATE_SELECTED_PLANTSUITE_DELETE="$(selected_svc_delete_list)"
    export UPDATE_SELECTED_INFRA
    export UPDATE_SELECTED_PLANTSUITE_APPLY
    export UPDATE_SELECTED_PLANTSUITE_DELETE

    {
      echo "APPLY_INFRA=${UPDATE_SELECTED_INFRA}"
      echo "APPLY_SERVICES=${UPDATE_SELECTED_PLANTSUITE_APPLY}"
      echo "DELETE_SERVICES=${UPDATE_SELECTED_PLANTSUITE_DELETE}"
    } > "$RESULT_FILE"
    return
  fi

  tui_init
  tui_init_colors

  # Posiciona cursor no primeiro item selecionavel (pula blank e separador iniciais).
  local selected=2 running=1 key i
  local need_redraw=1
  local footer_msg=""
  input_flush

  while [[ $running -eq 1 ]]; do
    if [[ ${TUI_RESIZE:-0} -eq 1 ]]; then
      tui_handle_resize
      need_redraw=1
    fi

    if [[ $need_redraw -eq 1 ]]; then
      tput cup 0 0 2>/dev/null || true
      draw_update_selection_screen "$selected" "$footer_msg"
      tput cup 0 0 2>/dev/null || true
      need_redraw=0
    fi

    key=$(read_key) || break
    case "$key" in
      UP)
        local old_selected="$selected"
        local tbl_top=$((HEADER_HEIGHT + 1))
        local tbl_h=$((TUI_LINES - tbl_top - 5))
        [[ $tbl_h -lt 10 ]] && tbl_h=10
        local cap=$((tbl_h - 2))
        local old_start new_start
        old_start=$(scroll_top "$UPD_ROWS_COUNT" "$old_selected" "$cap")

        selected=$(( (selected - 1 + UPD_ROWS_COUNT) % UPD_ROWS_COUNT ))
        while [[ "${UPD_ROWS[$selected]%%:*}" == "sep" || "${UPD_ROWS[$selected]%%:*}" == "blank" ]]; do
          selected=$(( (selected - 1 + UPD_ROWS_COUNT) % UPD_ROWS_COUNT ))
        done

        new_start=$(scroll_top "$UPD_ROWS_COUNT" "$selected" "$cap")
        if [[ "$new_start" != "$old_start" ]]; then
          need_redraw=1
        else
          draw_update_selection_row "$old_selected" "$selected" "$old_start" "$tbl_top" "$cap"
          draw_update_selection_row "$selected" "$selected" "$old_start" "$tbl_top" "$cap"
        fi
        ;;
      DOWN)
        local old_selected="$selected"
        local tbl_top=$((HEADER_HEIGHT + 1))
        local tbl_h=$((TUI_LINES - tbl_top - 5))
        [[ $tbl_h -lt 10 ]] && tbl_h=10
        local cap=$((tbl_h - 2))
        local old_start new_start
        old_start=$(scroll_top "$UPD_ROWS_COUNT" "$old_selected" "$cap")

        selected=$(( (selected + 1) % UPD_ROWS_COUNT ))
        while [[ "${UPD_ROWS[$selected]%%:*}" == "sep" || "${UPD_ROWS[$selected]%%:*}" == "blank" ]]; do
          selected=$(( (selected + 1) % UPD_ROWS_COUNT ))
        done

        new_start=$(scroll_top "$UPD_ROWS_COUNT" "$selected" "$cap")
        if [[ "$new_start" != "$old_start" ]]; then
          need_redraw=1
        else
          draw_update_selection_row "$old_selected" "$selected" "$old_start" "$tbl_top" "$cap"
          draw_update_selection_row "$selected" "$selected" "$old_start" "$tbl_top" "$cap"
        fi
        ;;
      SPACE) toggle_row_action "$selected"; footer_msg=""; need_redraw=1 ;;
      u|U) set_row_action "$selected" "apply"; footer_msg=""; need_redraw=1 ;;
      r|R) set_row_action "$selected" "delete"; footer_msg=""; need_redraw=1 ;;
      n|N) set_row_action "$selected" "none"; footer_msg=""; need_redraw=1 ;;
      x|X)
        for ((i=0; i<UPD_INFRA_COUNT; i++)); do
          UPD_INFRA_ACTION[$i]=0
        done
        for ((i=0; i<UPD_SVC_COUNT; i++)); do
          UPD_SVC_ACTION[$i]=0
        done
        footer_msg=""
        need_redraw=1
        ;;
      ENTER)
        if [[ -z "$(selected_infra_list)" && -z "$(selected_svc_apply_list)" && -z "$(selected_svc_delete_list)" ]]; then
          footer_msg="Selecione ao menos um item para continuar."
          need_redraw=1
          continue
        fi
        running=0
        ;;
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

  UPDATE_SELECTED_INFRA="$(selected_infra_list)"
  UPDATE_SELECTED_PLANTSUITE_APPLY="$(selected_svc_apply_list)"
  UPDATE_SELECTED_PLANTSUITE_DELETE="$(selected_svc_delete_list)"
  export UPDATE_SELECTED_INFRA
  export UPDATE_SELECTED_PLANTSUITE_APPLY
  export UPDATE_SELECTED_PLANTSUITE_DELETE

  {
    echo "APPLY_INFRA=${UPDATE_SELECTED_INFRA}"
    echo "APPLY_SERVICES=${UPDATE_SELECTED_PLANTSUITE_APPLY}"
    echo "DELETE_SERVICES=${UPDATE_SELECTED_PLANTSUITE_DELETE}"
  } > "$RESULT_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_screen_update_selection
fi
