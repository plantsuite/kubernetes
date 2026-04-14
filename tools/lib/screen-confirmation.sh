#!/usr/bin/env bash
# Tela 4/4 — Confirmação
# Revisão dos valores selecionados antes de aplicação.
LAYOUT_NAME="4/4 Confirmação"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

sorted_selected_services() {
    local svc
    for svc in $SELECTED_SERVICES; do
        printf '%s\n' "$svc"
    done | sort
}

count_selected_services() {
    local count=0
    local _svc
    while IFS= read -r _svc; do
        ((count++))
    done < <(sorted_selected_services)
    echo "$count"
}

build_infra_entries() {
    INFRA_ENTRIES=()

    local component src
    while IFS= read -r component; do
        src="$(infra_source_for_overlay "$component")"
        INFRA_ENTRIES+=("$component [$src]")
    done < <(printf '%s\n' "${INFRA_COMPONENTS[@]}" | sort)
}

draw_infra_grid() {
    local start_row="$1"
    local max_rows="$2"
    local inner_width="$3"
    local col_width=$(((inner_width - 2) / 2))
    local left_col=5
    local right_col=$((left_col + col_width + 2))
    local capacity=$((max_rows * 2))
    local shown=0
    local idx label row col

    for ((idx=0; idx<INFRA_COUNT && idx<capacity; idx++)); do
        row=$((start_row + idx / 2))
        if (( idx % 2 == 0 )); then
            col=$left_col
        else
            col=$right_col
        fi
        label="- ${INFRA_ENTRIES[$idx]}"
        at "$row" "$col" "$(trunc "$label" "$col_width")" "$C_DIM" "$col_width"
        ((shown++))
    done

    if (( INFRA_COUNT > capacity )); then
        at "$((start_row + max_rows - 1))" 5 "$(trunc "... +$((INFRA_COUNT - capacity + 1)) componentes" "$inner_width")" "$C_DIM"
    fi
}

service_source_for_overlay() {
    local service="$1"
    local overlay="${SELECTED_OVERLAY:-}"
    local overlay_service_dir="$ROOT_DIR/../k8s/overlays/$overlay/plantsuite/$service"
    local overlay_patch_dir="$ROOT_DIR/../k8s/overlays/$overlay/plantsuite/patches/$service"

    if [[ -d "$overlay_service_dir" || -d "$overlay_patch_dir" ]]; then
        echo "overlay"
    else
        echo "base"
    fi
}

draw_confirmation_screen() {
    draw_header

    build_infra_entries

    local top=$((HEADER_HEIGHT + 1))
    local h=$((TUI_LINES - top - 2))
    [[ $h -lt 10 ]] && h=10
    draw_box "$top" 1 "$h" "$((TUI_COLS-2))" "Revisão da Instalação"

    local row=$((top + 2))
    local inner_width=$((TUI_COLS - 8))
    local bottom_row=$((top + h - 2))
    local infra_rows=$(((INFRA_COUNT + 1) / 2))
    local min_service_rows=3
    local selected_service_count
    selected_service_count="$(count_selected_services)"

    at "$row" 3 "Contexto: $(trunc "$SELECTED_CONTEXT" $((inner_width - 10)))" "$C_DIM"
    ((row++))
    at "$row" 3 "Overlay: $(trunc "$SELECTED_OVERLAY" $((inner_width - 9)))" "$C_DIM"
    ((row++))
    ((row++))
    at "$row" 3 "Infraestrutura (${INFRA_COUNT} componentes):" "$C_ACCENT"
    ((row++))

    draw_infra_grid "$row" "$infra_rows" "$inner_width"
    row=$((row + infra_rows))

    ((row++))
    at "$row" 3 "Serviços PlantSuite (${selected_service_count} componentes):" "$C_ACCENT"
    ((row++))

    local max_service_rows=$((bottom_row - row + 1))
    [[ $max_service_rows -lt $min_service_rows ]] && max_service_rows=$min_service_rows
    local shown=0
    local total=0
    local svc src line
    while IFS= read -r svc; do
        ((total++))
        if [[ $shown -lt $max_service_rows ]]; then
            src="$(service_source_for_overlay "$svc")"
            line="- $svc [$src]"
            at "$row" 5 "$(trunc "$line" $((TUI_COLS-8)))" "$C_DIM"
            ((row++))
            ((shown++))
        fi
    done < <(sorted_selected_services)
    if [[ $total -gt $shown ]]; then
        at "$row" 5 "$(trunc "... +$((total-shown)) serviços" $((TUI_COLS-8)))" "$C_DIM"
        ((row++))
    fi

    # Footer
    tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
    tput el 2>/dev/null || true
    colorize_hint "  enter confirmar   b voltar   q sair"
}

run_screen_confirmation() {
    HEADER_SUBTITLE="Confirme os valores e pressione ENTER para instalar"
    HEADER_CTX="contexto: ${SELECTED_CONTEXT:-} | overlay: ${SELECTED_OVERLAY:-}"

    tui_check_compat
    if [[ $TUI_PLAIN -eq 1 ]]; then
        build_infra_entries
        echo ""
        echo "=== Confirmação ==="
        echo "Contexto    : $SELECTED_CONTEXT"
        echo "Overlay     : $SELECTED_OVERLAY"
        echo ""
        echo "Infraestrutura:"
        local item
        for item in "${INFRA_ENTRIES[@]}"; do
            printf '  - %s\n' "$item"
        done
        echo ""
        echo "Serviços PlantSuite ($(count_selected_services) componentes):"
        local svc src
        while IFS= read -r svc; do
            src="$(service_source_for_overlay "$svc")"
            printf '  - %s [%s]\n' "$svc" "$src"
        done < <(sorted_selected_services)
        echo ""
        read -rp "Confirmar instalação? (s/n/b=voltar/q=sair): " -n 1 confirm
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
    if ! tui_wait_min_size; then
        _tui_cleanup
        build_infra_entries
        echo ""
        echo "=== Confirmação ==="
        echo "Contexto    : $SELECTED_CONTEXT"
        echo "Overlay     : $SELECTED_OVERLAY"
        echo ""
        echo "Infraestrutura:"
        local item
        for item in "${INFRA_ENTRIES[@]}"; do
            printf '  - %s\n' "$item"
        done
        echo ""
        echo "Serviços PlantSuite ($(count_selected_services) componentes):"
        local svc src
        while IFS= read -r svc; do
            src="$(service_source_for_overlay "$svc")"
            printf '  - %s [%s]\n' "$svc" "$src"
        done < <(sorted_selected_services)
        echo ""
        read -rp "Confirmar instalação? (s/n/b=voltar/q=sair): " -n 1 confirm
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

    local running=1 key="QUIT"
    input_flush

    while [[ $running -eq 1 ]]; do
        _tui_move_cursor 0 0
        draw_confirmation_screen
        _tui_move_cursor 0 0

        local key; key=$(read_key) || continue
        case "$key" in
            RESIZE)
                tui_on_resize
                ;;
            ENTER)
                running=0
                ;;
            b)
                running=0
                key="BACK"
                ;;
            QUIT|ESC|q)
                running=0
                ;;
        esac
    done

    _tui_cleanup
    trap - EXIT INT TERM WINCH

    if [[ "$key" == "QUIT" || "$key" == "q" ]]; then
        if [[ -n "${RESULT_FILE:-}" ]]; then
            echo "__QUIT__" > "$RESULT_FILE"
        else
            echo "__QUIT__"
        fi
    elif [[ "$key" == "BACK" ]]; then
        if [[ -n "${RESULT_FILE:-}" ]]; then
            echo "__BACK__" > "$RESULT_FILE"
        else
            echo "__BACK__"
        fi
    elif [[ "$key" != "QUIT" ]]; then
        if [[ -n "${RESULT_FILE:-}" ]]; then
            echo "confirmed" > "$RESULT_FILE"
        else
            echo "confirmed"
        fi
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_screen_confirmation
fi
