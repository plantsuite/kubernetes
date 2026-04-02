#!/usr/bin/env bash
# Tela 1/4 — Seleção do Contexto Kubernetes
# Contextos exibidos como tabela com colunas: Nome, Cluster e Namespace.
LAYOUT_NAME="1/4 Contexto"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

draw_context_screen() {
    local sel="$1"

    # Fallback para telas estreitas
    if [[ $TUI_COLS -lt 80 ]]; then
        draw_header
        local top=3 h=$((TUI_LINES - 6))
        draw_box "$top" 1 "$h" "$((TUI_COLS-2))" "Contextos"
        draw_list "$((top+1))" 2 "$((h-2))" "$((TUI_COLS-4))" "$sel"
        draw_footer "$((sel+1))/${CTX_COUNT} contextos"
        return
    fi

    draw_header

    # Larguras das colunas — escala com a largura total
    local w_name w_cluster w_ns
    if [[ $TUI_COLS -gt 120 ]]; then
        w_name=36; w_cluster=32; w_ns=20
    elif [[ $TUI_COLS -gt 100 ]]; then
        w_name=30; w_cluster=26; w_ns=18
    else
        w_name=24; w_cluster=20; w_ns=14
    fi

    local tbl_top=3
    local tbl_h=$((TUI_LINES - 7))
    draw_box "$tbl_top" 1 "$tbl_h" "$((TUI_COLS-2))" "Contextos Kubernetes"

    # Cabeçalho da tabela
    local hdr
    printf -v hdr "  %-${w_name}s  %-${w_cluster}s  %-${w_ns}s" \
        "CONTEXTO" "CLUSTER" "NAMESPACE"
    at "$((tbl_top+1))" 2 "$(trunc "$hdr" $((TUI_COLS-4)))" "$C_ACCENT"
    tput cup "$((tbl_top+2))" 2 2>/dev/null || true
    printf '%s%*s%s' "$C_DIM" "$((TUI_COLS-4))" '' "$C_RESET" | tr ' ' '-'

    # Linhas
    local cap=$((tbl_h - 4))
    local top; top=$(scroll_top "$CTX_COUNT" "$sel" "$cap")
    local i=0
    while [[ $i -lt $cap && $((i+top)) -lt $CTX_COUNT ]]; do
        local idx=$((i+top))
        local row; printf -v row "  %-${w_name}s  %-${w_cluster}s  %-${w_ns}s" \
            "$(trunc "${CTX_NAMES[$idx]}" $w_name)" \
            "$(trunc "${CTX_CLUSTERS[$idx]}" $w_cluster)" \
            "$(trunc "${CTX_NAMESPACES[$idx]}" $w_ns)"
        local attr=""; [[ $idx -eq $sel ]] && attr="$C_SELECTED"
        at "$((tbl_top+3+i))" 2 "$(trunc "$row" $((TUI_COLS-4)))" "$attr"
        ((i++)) || true
    done

    # Linha de status abaixo da tabela
    local status_row=$((tbl_top + tbl_h))
    local status="  Selecionado: ${CTX_NAMES[$sel]}   cluster: ${CTX_CLUSTERS[$sel]}   API: ${CTX_SERVERS[$sel]}"
    at "$status_row" 0 "$(trunc "$status" $((TUI_COLS-2)))" "$C_DIM"

    draw_footer "$((sel+1))/${CTX_COUNT} contextos"
}

run_screen_context() {
    HEADER_SUBTITLE="Use as setas para navegar e ENTER para selecionar o contexto"
    HEADER_CTX=""
    draw_screen() { draw_context_screen "$@"; }
    run_tui
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_screen_context
fi
