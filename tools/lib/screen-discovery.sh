#!/usr/bin/env bash
# Tela intermediária para descoberta de modo (instalação x atualização)
LAYOUT_NAME="Descoberta"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

draw_discovery_screen() {
  local phase="${1:-Analisando cluster...}"

  draw_header

  local top=$((HEADER_HEIGHT + 1))
  local h=$((TUI_LINES - top - 3))
  [[ $h -lt 10 ]] && h=10

  draw_box "$top" 1 "$h" "$((TUI_COLS-2))" "Descoberta do Ambiente"

  local row=$((top + 2))
  at "$row" 3 "Validando recursos instalados para definir o fluxo..." "$C_ACCENT"
  row=$((row + 2))

  at "$row" 5 "- Infraestrutura PlantSuite" "$C_DIM"
  row=$((row + 1))
  at "$row" 5 "- Serviços PlantSuite" "$C_DIM"
  row=$((row + 2))

  at "$row" 3 "$phase" "$C_WARN"

  tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
  tput el 2>/dev/null || true
  colorize_hint "  aguarde..."
}

run_screen_discovery() {
  HEADER_SUBTITLE="Detectando automaticamente: instalação ou atualização"
  HEADER_CTX="contexto: ${SELECTED_CONTEXT:-} | overlay: ${SELECTED_OVERLAY:-}"

  tui_check_compat
  if [[ $TUI_PLAIN -eq 1 ]]; then
    echo ""
    echo "Detectando ambiente do cluster..."
    detect_auto_mode >/dev/null
    local mode="$UPDATE_DETECTED_MODE"
    [[ -n "${RESULT_FILE:-}" ]] && echo "$mode" > "$RESULT_FILE" || echo "$mode"
    return
  fi

  tui_init
  tui_init_colors
  if ! tui_wait_min_size; then
    _tui_cleanup
    echo ""
    echo "Detectando ambiente do cluster..."
    detect_auto_mode >/dev/null
    local mode="$UPDATE_DETECTED_MODE"
    [[ -n "${RESULT_FILE:-}" ]] && echo "$mode" > "$RESULT_FILE" || echo "$mode"
    return
  fi

  printf '\033[3J\033[2J\033[H'
  draw_discovery_screen "Analisando cluster..."

  local _disc_tmp
  _disc_tmp=$(mktemp)
  detect_auto_mode > "$_disc_tmp" 2>&1 &
  local _disc_pid=$!

  while kill -0 "$_disc_pid" 2>/dev/null; do
    IFS= read -rsn1 -t 0.2 _dk 2>/dev/null || true
    local nc nl
    nc=$(tput cols 2>/dev/null || echo 80)
    nl=$(tput lines 2>/dev/null || echo 24)
    if [[ $nc -ne $TUI_COLS || $nl -ne $TUI_LINES ]]; then
      TUI_COLS=$nc; TUI_LINES=$nl
      printf '\033[3J\033[2J\033[H'
      draw_discovery_screen "Analisando cluster..."
    fi
  done

  wait "$_disc_pid" 2>/dev/null || true

  local mode
  mode=$(cat "$_disc_tmp" 2>/dev/null || true)
  rm -f "$_disc_tmp"
  [[ -z "$mode" ]] && mode="install"

  # Re-executa no shell pai para popular as variáveis de estado usadas pela tela de update.
  detect_auto_mode >/dev/null 2>&1 || true

  printf '\033[3J\033[2J\033[H'
  draw_discovery_screen "Detecção concluída: modo ${mode}."

  local _show_ticks=0
  while [[ $_show_ticks -lt 2 ]]; do
    IFS= read -rsn1 -t 0.5 wk 2>/dev/null && break
    local nc nl
    nc=$(tput cols 2>/dev/null || echo 80)
    nl=$(tput lines 2>/dev/null || echo 24)
    if [[ $nc -ne $TUI_COLS || $nl -ne $TUI_LINES ]]; then
      TUI_COLS=$nc; TUI_LINES=$nl
      printf '\033[3J\033[2J\033[H'
      draw_discovery_screen "Detecção concluída: modo ${mode}."
    fi
    _show_ticks=$(( _show_ticks + 1 ))
  done

  _tui_cleanup
  trap - EXIT INT TERM WINCH

  [[ -n "${RESULT_FILE:-}" ]] && echo "$mode" > "$RESULT_FILE" || echo "$mode"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_screen_discovery
fi
