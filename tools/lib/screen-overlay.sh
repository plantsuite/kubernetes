#!/usr/bin/env bash
# Tela 2/4 — Seleção do Overlay
# Apresenta os overlays disponíveis (k8s/overlays/*) e retorna o escolhido.
# Espera a variável de ambiente SELECTED_CONTEXT para exibir breadcrumb.
LAYOUT_NAME="2/4 Overlay"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

HEADER_SUBTITLE="Selecione o overlay de instalação"
HEADER_CTX="contexto: ${SELECTED_CONTEXT:-}"

ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAYS_DIR="$ROOT_DIR/../k8s/overlays"

# ── Dados dos overlays ────────────────────────────────────────────────────────
declare -a OVL_NAMES=()
declare -a OVL_ADJUSTED_COUNT=()
declare -a OVL_COMPONENTS=()

count_overlay_adjusted_services() {
    local overlay_dir="$1"
    local count=0
    local component
    while IFS= read -r component; do
        if [[ -f "$component/kustomization.yaml" ]]; then
            ((count++))
        fi
    done < <(find "$overlay_dir" -mindepth 1 -maxdepth 1 -type d | sort)

    echo "$count"
}

list_overlay_components() {
    local overlay_dir="$1"
    local components=""
    local component name

    while IFS= read -r component; do
        if [[ -f "$component/kustomization.yaml" ]]; then
            name="$(basename "$component")"
            [[ -n "$components" ]] && components+=", "
            components+="$name"
        fi
    done < <(find "$overlay_dir" -mindepth 1 -maxdepth 1 -type d | sort)

    echo "$components"
}

load_overlays() {
    OVL_NAMES=()
    OVL_ADJUSTED_COUNT=()
    OVL_COMPONENTS=()

    local d name
    if [[ -d "$OVERLAYS_DIR" ]]; then
        while IFS= read -r d; do
            name="$(basename "$d")"

            OVL_NAMES+=("$name")
            OVL_ADJUSTED_COUNT+=("$(count_overlay_adjusted_services "$d")")
            OVL_COMPONENTS+=("$(list_overlay_components "$d")")
        done < <(find "$OVERLAYS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    fi

    MENU_COUNT=${#OVL_NAMES[@]}
    MENU_ITEMS=("${OVL_NAMES[@]}")
    MENU_VALUES=("${OVL_NAMES[@]}")
}

# ── Tela ─────────────────────────────────────────────────────────────────────
draw_overlay_screen() {
    local sel="$1"

    draw_header

    local tbl_top=$((HEADER_HEIGHT + 1))
    local tbl_h=$((TUI_LINES - tbl_top - 4))
    [[ $tbl_h -lt 6 ]] && tbl_h=6

    draw_box "$tbl_top" 1 "$tbl_h" "$((TUI_COLS-2))" "Overlays Disponíveis"

    local w_name=26
    local w_components
    w_components=$((TUI_COLS - w_name - 8))
    [[ $w_components -lt 20 ]] && w_components=20

    local hdr
    printf -v hdr "  %-${w_name}s  %-${w_components}s" \
        "OVERLAY (AJUSTES)" "COMPONENTES"
    at "$((tbl_top+1))" 2 "$(trunc "$hdr" $((TUI_COLS-4)))" "$C_ACCENT"

    tput cup "$((tbl_top+2))" 2 2>/dev/null || true
    printf '%s%*s%s' "$C_DIM" "$((TUI_COLS-4))" '' "$C_RESET" | tr ' ' '-'

    local i
    for ((i=0; i<MENU_COUNT; i++)); do
        local row
        local overlay_cell="${OVL_NAMES[$i]} (${OVL_ADJUSTED_COUNT[$i]})"
        printf -v row "  %-${w_name}s  %-${w_components}s" \
            "$(trunc "$overlay_cell" $w_name)" \
            "$(trunc "${OVL_COMPONENTS[$i]}"  $w_components)"

        local attr=""
        [[ $i -eq $sel ]] && attr="$C_SELECTED"
        clear_area "$((tbl_top+3+i))" 2 "$((TUI_COLS-4))"
        at "$((tbl_top+3+i))" 2 "$(trunc "$row" $((TUI_COLS-4)))" "$attr"
    done

    local status="  Selecionado: ${OVL_NAMES[$sel]}   componentes ajustados: ${OVL_ADJUSTED_COUNT[$sel]}"
    clear_area "$((tbl_top+tbl_h))" 0 "$((TUI_COLS-2))"
    at "$((tbl_top+tbl_h))" 0 "$(trunc "$status" $((TUI_COLS-2)))" "$C_DIM"

    local hint="  ↑↓ navegar   b voltar   enter selecionar   q sair"
    tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
    tput el 2>/dev/null || true
    colorize_hint "$(trunc "$hint" $((TUI_COLS / 2)))"
    at "$((TUI_LINES - 1))" $((TUI_COLS / 2)) "$((sel+1))/${MENU_COUNT} overlays" "$C_ACCENT" $((TUI_COLS / 2 - 2))
}

run_screen_overlay() {
    load_overlays
    if [[ $MENU_COUNT -eq 0 ]]; then
        return 1
    fi

    HEADER_SUBTITLE="Selecione o overlay de instalação"
    HEADER_CTX="contexto: ${SELECTED_CONTEXT:-}"

    # run_menu chama uma função global draw_screen; rebind aqui para evitar
    # colisão com a tela de contexto (que também define draw_screen).
    draw_screen() {
        draw_overlay_screen "$@"
    }

    run_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_screen_overlay
fi
