#!/usr/bin/env bash
# Tela 1/4 — Seleção do Contexto Kubernetes
# Contextos exibidos como tabela com colunas: Nome, Cluster e Namespace.
LAYOUT_NAME="1/4 Contexto"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

CONTEXT_STATUS=""

context_reset_secrets() {
    local answer

    if [[ "${TUI_PLAIN:-0}" -eq 1 ]]; then
        printf '\nATENÇÃO: isso limpará somente os arquivos locais de secrets gerenciados.\n'
        printf 'Nenhum Secret do cluster será alterado. Continuar? (s/N): '
        read -r answer
        if [[ ! "$answer" =~ ^[sS]$ ]]; then
            echo "Limpeza cancelada; nenhum arquivo foi alterado."
            return 0
        fi
        if reset_managed_secrets_files; then
            echo "Arquivos locais de secrets limpos."
            return 0
        else
            echo "ERRO: não foi possível limpar os arquivos locais de secrets." >&2
            return 1
        fi
    fi

    clear_area "$((TUI_LINES - 4))" 0 "$TUI_COLS"
    clear_area "$((TUI_LINES - 3))" 0 "$TUI_COLS"
    at "$((TUI_LINES - 4))" 2 "ATENÇÃO: limpar somente os arquivos locais de secrets gerenciados?" "$C_WARN"
    at "$((TUI_LINES - 3))" 2 "Nenhum Secret do cluster será alterado. Confirmar com S; qualquer outra tecla cancela." "$C_DIM"
    answer=$(read_key)
    # O loop principal redesenha a partir de (0,0); remova o prompt antes
    # de voltar a desenhar para não deixar sua segunda linha sobre a tabela.
    clear_area "$((TUI_LINES - 4))" 0 "$TUI_COLS"
    clear_area "$((TUI_LINES - 3))" 0 "$TUI_COLS"
    if [[ "$answer" =~ ^[sS]$ ]]; then
        # O reset chama klog(), que escreve em stdout. Em full-screen isso
        # corromperia a tela na posição atual do cursor.
        if reset_managed_secrets_files >/dev/null 2>&1; then
            CONTEXT_STATUS="Arquivos locais de secrets limpos."
        else
            CONTEXT_STATUS="ERRO: não foi possível limpar os arquivos locais de secrets."
        fi
    else
        CONTEXT_STATUS="Limpeza cancelada; nenhum arquivo foi alterado."
    fi
    return 0
}

context_handle_key() {
    [[ "$1" =~ ^[rR]$ ]] || return 1
    context_reset_secrets
    return 0
}

draw_context_screen() {
    local sel="$1"

    # Fallback para telas estreitas
    if [[ $TUI_COLS -lt 80 ]]; then
        draw_header
        local top=3 h=$((TUI_LINES - 6))
        draw_box "$top" 1 "$h" "$((TUI_COLS-2))" "Contextos"
        draw_list "$((top+1))" 2 "$((h-2))" "$((TUI_COLS-4))" "$sel"
        # Linha de status abaixo da tabela (mantém apenas API que não está na tabela)
    local status_row=$((top + h))
    local status="  API: ${CTX_SERVERS[$sel]}"
    at "$status_row" 0 "$(trunc "$status" $((TUI_COLS-2)))" "$C_DIM"

    draw_footer "${CONTEXT_STATUS}"
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

    # Linha de status abaixo da tabela (mantém apenas API que não está na tabela)
    local status_row=$((tbl_top + tbl_h))
    local status="  API: ${CTX_SERVERS[$sel]}"
    at "$status_row" 0 "$(trunc "$status" $((TUI_COLS-2)))" "$C_DIM"

    draw_footer "${CONTEXT_STATUS}"
}

run_screen_context() {
    HEADER_SUBTITLE="Use as setas para navegar e ENTER para selecionar o contexto"
    HEADER_CTX=""
    CONTEXT_STATUS=""
    TUI_FOOTER_HINT="  ↑↓ navegar   enter selecionar   r limpar secrets locais   q sair  "
    TUI_KEY_HANDLER=context_handle_key
    draw_screen() { draw_context_screen "$@"; }
    run_tui
    TUI_KEY_HANDLER=""
    TUI_FOOTER_HINT=""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_screen_context
fi
