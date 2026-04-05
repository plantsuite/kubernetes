#!/usr/bin/env bash
# Tela Update — Confirmação com destaque de remoções
LAYOUT_NAME="Update Confirmação"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

count_words() {
  local n=0 _w
  for _w in $1; do
    ((n++))
  done
  echo "$n"
}

# Resultado de draw_word_list: linha seguinte após o bloco renderizado.
_WORD_LIST_ROW=0

draw_word_list() {
  local row="$1"
  local title="$2"
  local items="$3"
  local color="$4"
  local max_rows="$5"

  at "$row" 3 "$title" "$C_ACCENT"
  row=$((row + 1))

  local shown=0 item
  for item in $items; do
    if [[ $shown -ge $max_rows ]]; then
      at "$row" 5 "..." "$C_DIM"
      row=$((row + 1))
      _WORD_LIST_ROW="$row"
      return
    fi
    at "$row" 5 "- $item" "$color"
    row=$((row + 1))
    shown=$((shown + 1))
  done

  if [[ -z "$items" ]]; then
    at "$row" 5 "- nenhum" "$C_DIM"
    row=$((row + 1))
  fi

  _WORD_LIST_ROW="$row"
}

draw_update_confirmation_screen() {
  draw_header

  local top=$((HEADER_HEIGHT + 1))
  local h=$((TUI_LINES - top - 2))
  [[ $h -lt 12 ]] && h=12
  draw_box "$top" 1 "$h" "$((TUI_COLS-2))" "Revisão da Atualização"

  local row=$((top + 2))
  local max_rows=4

  at "$row" 3 "Contexto: ${SELECTED_CONTEXT}" "$C_DIM"
  row=$((row + 1))
  at "$row" 3 "Overlay: ${SELECTED_OVERLAY}" "$C_DIM"
  row=$((row + 2))

  local infra_count svc_apply_count svc_delete_count
  infra_count=$(count_words "$UPDATE_SELECTED_INFRA")
  svc_apply_count=$(count_words "$UPDATE_SELECTED_PLANTSUITE_APPLY")
  svc_delete_count=$(count_words "$UPDATE_SELECTED_PLANTSUITE_DELETE")

  at "$row" 3 "Resumo: infra=$infra_count  aplicar-serviços=$svc_apply_count  remover-serviços=$svc_delete_count" "$C_DIM"
  row=$((row + 2))

  draw_word_list "$row" "Infra para atualizar:" "$UPDATE_SELECTED_INFRA" "$C_DIM" "$max_rows"
  row=$((_WORD_LIST_ROW + 1))

  draw_word_list "$row" "Serviços para aplicar/instalar:" "$UPDATE_SELECTED_PLANTSUITE_APPLY" "$C_WARN" "$max_rows"
  row=$((_WORD_LIST_ROW + 1))

  draw_word_list "$row" "Serviços para remover (ATENÇÃO):" "$UPDATE_SELECTED_PLANTSUITE_DELETE" "$C_ERROR" "$max_rows"

  tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
  tput el 2>/dev/null || true
  colorize_hint "  enter confirmar   b voltar   q sair"
}

run_screen_update_confirmation() {
  HEADER_SUBTITLE="Confirme a atualização antes de executar"
  HEADER_CTX="contexto: ${SELECTED_CONTEXT:-} | overlay: ${SELECTED_OVERLAY:-}"

  tui_check_compat
  if [[ $TUI_PLAIN -eq 1 ]]; then
    echo ""
    echo "=== Confirmação da Atualização ==="
    echo "Contexto: $SELECTED_CONTEXT"
    echo "Overlay : $SELECTED_OVERLAY"
    echo ""
    echo "Infra para atualizar: ${UPDATE_SELECTED_INFRA:-nenhum}"
    echo "Serviços para aplicar/instalar: ${UPDATE_SELECTED_PLANTSUITE_APPLY:-nenhum}"
    echo "Serviços para remover: ${UPDATE_SELECTED_PLANTSUITE_DELETE:-nenhum}"

    if [[ -n "$UPDATE_SELECTED_PLANTSUITE_DELETE" ]]; then
      echo ""
      read -rp "Digite REMOVER para confirmar remoções: " remove_confirm
      if [[ "$remove_confirm" != "REMOVER" ]]; then
        [[ -n "${RESULT_FILE:-}" ]] && echo "__BACK__" > "$RESULT_FILE" || echo "__BACK__"
        return
      fi
    fi

    echo ""
    read -rp "Executar atualização? (s/n/b=voltar/q=sair): " -n 1 confirm
    echo ""
    if [[ "$confirm" =~ [qQ] ]]; then
      echo "__QUIT__" > "$RESULT_FILE"
      return
    fi
    if [[ "$confirm" =~ [bB] ]]; then
      echo "__BACK__" > "$RESULT_FILE"
      return
    fi
    if [[ "$confirm" =~ [sS] ]]; then
      echo "confirmed" > "$RESULT_FILE"
    fi
    return
  fi

  tui_init
  tui_init_colors

  local running=1 key="QUIT"
  input_flush

  while [[ $running -eq 1 ]]; do
    tui_handle_resize
    tput cup 0 0 2>/dev/null || true
    draw_update_confirmation_screen
    tput cup 0 0 2>/dev/null || true

    key=$(read_key) || break
    case "$key" in
      ENTER)
        if [[ -n "$UPDATE_SELECTED_PLANTSUITE_DELETE" ]]; then
          local prompt="Confirme remoção digitando REMOVER: "
          tput cup "$((TUI_LINES - 2))" 3 2>/dev/null || true
          tput el 2>/dev/null || true
          printf '%s%s%s' "$C_ERROR" "$prompt" "$C_RESET"
          stty echo 2>/dev/null || true
          local remove_confirm
          IFS= read -r remove_confirm
          stty -echo 2>/dev/null || true
          if [[ "$remove_confirm" != "REMOVER" ]]; then
            continue
          fi
        fi
        running=0
        ;;
      b)
        running=0
        key="BACK"
        ;;
      QUIT|ESC|q)
        running=0
        key="QUIT"
        ;;
    esac
  done

  _tui_cleanup
  trap - EXIT INT TERM WINCH

  if [[ "$key" == "QUIT" || "$key" == "q" ]]; then
    [[ -n "${RESULT_FILE:-}" ]] && echo "__QUIT__" > "$RESULT_FILE" || echo "__QUIT__"
  elif [[ "$key" == "BACK" ]]; then
    [[ -n "${RESULT_FILE:-}" ]] && echo "__BACK__" > "$RESULT_FILE" || echo "__BACK__"
  else
    [[ -n "${RESULT_FILE:-}" ]] && echo "confirmed" > "$RESULT_FILE" || echo "confirmed"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_screen_update_confirmation
fi
