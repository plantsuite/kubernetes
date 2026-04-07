#!/usr/bin/env bash
# Tela 3/4 — Seleção de Serviços PlantSuite
# Suporta seleção múltipla com SPACE, e atalhos para pré-seleção.
LAYOUT_NAME="3/4 Serviços"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/tui.sh
source "$SCRIPT_DIR/common/tui.sh"

# ── Dados de serviços ────────────────────────────────────────────────────────
# Ordenado alfabeticamente.
declare -a SVC_NAMES=(
    "alarms" "controlstations" "dashboards" "devices" "entities"
    "gateway" "mes" "notifications" "portal" "production"
    "queries" "spc" "tenants" "timeseries-buffer" "timeseries-mqtt"
    "wd" "workflows"
)

declare -a SVC_GROUP=(
    "IoT" "MES" "IoT" "IoT" "IoT"
    "MES" "MES" "IoT" "IoT" "MES"
    "IoT" "IoT" "IoT" "IoT" "IoT"
    "MES" "IoT"
)

SVC_COUNT=${#SVC_NAMES[@]}

# Serviços obrigatórios (sempre pré-selecionados, não removíveis)
declare -a SVC_MANDATORY=()
for ((i=0; i<SVC_COUNT; i++)); do
    case "${SVC_NAMES[$i]}" in
        portal|tenants) SVC_MANDATORY[$i]=1 ;;
        *) SVC_MANDATORY[$i]=0 ;;
    esac
done

# Estado de seleção: 1=marcado, 0=desmarcado
declare -a SVC_SELECTED=()
for ((i=0; i<SVC_COUNT; i++)); do
    SVC_SELECTED[$i]=${SVC_MANDATORY[$i]}
done

# ── Funções auxiliares ───────────────────────────────────────────────────────
mark_group() {
    local group="$1" value="$2"
    local i
    for ((i=0; i<SVC_COUNT; i++)); do
        if [[ "${SVC_GROUP[$i]}" == "$group" ]]; then
            # ao limpar (value=0), não remove obrigatórios
            [[ $value -eq 0 && ${SVC_MANDATORY[$i]} -eq 1 ]] && continue
            SVC_SELECTED[$i]=$value
        fi
    done
}

toggle_service() {
    local idx="$1"
    if [[ $idx -ge 0 && $idx -lt $SVC_COUNT ]]; then
        # serviços obrigatórios não podem ser desmarcados
        [[ ${SVC_MANDATORY[$idx]} -eq 1 ]] && return
        SVC_SELECTED[$idx]=$(( 1 - SVC_SELECTED[$idx] ))
    fi
}

get_selected_services() {
    local i result=""
    for ((i=0; i<SVC_COUNT; i++)); do
        if [[ ${SVC_SELECTED[$i]} -eq 1 ]]; then
            [[ -n "$result" ]] && result="$result "
            result="$result${SVC_NAMES[$i]}"
        fi
    done
    echo "$result"
}

# ── Tela ─────────────────────────────────────────────────────────────────────
draw_services_screen() {
    local sel="$1"

    draw_header

    local tbl_top=$((HEADER_HEIGHT + 1))
    local tbl_h=$((TUI_LINES - tbl_top - 5))
    [[ $tbl_h -lt 8 ]] && tbl_h=8

    draw_box "$tbl_top" 1 "$tbl_h" "$((TUI_COLS-2))" "Selecione os Serviços PlantSuite"

    at "$((tbl_top+1))" 2 "$(trunc "  SERVIÇOS PLANTSUITE" $((TUI_COLS-4)))" "$C_ACCENT"

    tput cup "$((tbl_top+2))" 2 2>/dev/null || true
    printf '%s%*s%s' "$C_DIM" "$((TUI_COLS-4))" '' "$C_RESET" | tr ' ' '-'

    local cap=$((tbl_h - 4))
    local start; start=$(scroll_top "$SVC_COUNT" "$sel" "$cap")
    local i=0
    while [[ $i -lt $cap && $((i+start)) -lt $SVC_COUNT ]]; do
        local idx=$((i+start))
        local checkbox="[ ]"
        if [[ ${SVC_MANDATORY[$idx]} -eq 1 ]]; then
            checkbox="[*]"
        elif [[ ${SVC_SELECTED[$idx]} -eq 1 ]]; then
            checkbox="[x]"
        fi

        local label=" $checkbox  ${SVC_NAMES[$idx]}"
        local attr=""
        [[ $idx -eq $sel ]] && attr="$C_SELECTED"

        tput cup "$((tbl_top+3+i))" 2 2>/dev/null || true
        clear_area "$((tbl_top+3+i))" 2 "$((TUI_COLS-4))"
        tput cup "$((tbl_top+3+i))" 2 2>/dev/null || true

        if [[ -n "$attr" ]]; then
            printf '%s%s%s' "$attr" "$(trunc "$label" $((TUI_COLS-4)))" "$C_RESET"
        else
            printf '%s' "$(trunc "$label" $((TUI_COLS-4)))"
        fi
        ((i++)) || true
    done

    local selected_count=0
    for ((i=0; i<SVC_COUNT; i++)); do
        [[ ${SVC_SELECTED[$i]} -eq 1 ]] && ((selected_count++))
    done

    local status="  Selecionados: $selected_count/${SVC_COUNT}   |   Infra: ${INFRA_COUNT} componentes sempre incluídos"
    at "$((tbl_top+tbl_h))" 0 "$(trunc "$status" $((TUI_COLS-2)))" "$C_DIM"

    local hint="  ↑↓ navegar   space marcar   i=iot   m=mes   t=tudo   c=limpar   [*]=obrigatório   b voltar   enter confirmar   q sair"
    tput cup "$((TUI_LINES - 1))" 0 2>/dev/null || true
    tput el 2>/dev/null || true
    colorize_hint "$(trunc "$hint" "$TUI_COLS")"
}

run_screen_services() {
    HEADER_SUBTITLE="Selecione os serviços PlantSuite a instalar"
    HEADER_CTX="contexto: ${SELECTED_CONTEXT:-} | overlay: ${SELECTED_OVERLAY:-}"

    tui_check_compat
    if [[ $TUI_PLAIN -eq 1 ]]; then
        echo ""
        echo "=== Serviços PlantSuite Disponíveis ==="
        [[ -n "$HEADER_CTX" ]] && echo "Contexto/Overlay: $HEADER_CTX"
        echo "Infra incluída: ${INFRA_COUNT} componentes sempre instalados"
        echo ""
        local i
        for ((i=0; i<SVC_COUNT; i++)); do
            printf '  %2d) %s\n' "$((i+1))" "${SVC_NAMES[$i]}"
        done
        echo ""
        printf 'Digite os números dos serviços desejados (ex: 1,2,5), B para voltar, Q para sair: '
        read -r selection

        if [[ "$selection" =~ ^[qQ]$ ]]; then
            if [[ -n "${RESULT_FILE:-}" ]]; then
                echo "__QUIT__" > "$RESULT_FILE"
            else
                echo "__QUIT__"
            fi
            return
        fi

        if [[ "$selection" =~ ^[bB]$ ]]; then
            if [[ -n "${RESULT_FILE:-}" ]]; then
                echo "__BACK__" > "$RESULT_FILE"
            else
                echo "__BACK__"
            fi
            return
        fi

        if [[ -n "$selection" ]]; then
            IFS=',' read -ra choices <<< "$selection"
            for choice in "${choices[@]}"; do
                choice=$(echo "$choice" | xargs)
                if [[ $choice =~ ^[0-9]+$ ]] && [[ $choice -ge 1 && $choice -le $SVC_COUNT ]]; then
                    SVC_SELECTED[$((choice-1))]=1
                fi
            done
        fi

        local result
        result=$(get_selected_services)
        if [[ -n "${RESULT_FILE:-}" ]]; then
            echo "$result" > "$RESULT_FILE"
        else
            echo "$result"
        fi
        return
    fi

    tui_init
    tui_init_colors

    local selected=0 running=1 key=""
    input_flush

    while [[ $running -eq 1 ]]; do
        tui_handle_resize
        tput cup 0 0 2>/dev/null || true
        draw_services_screen "$selected"
        tput cup 0 0 2>/dev/null || true

        local key; key=$(read_key) || break
        case "$key" in
            UP)
                selected=$(( (selected - 1 + SVC_COUNT) % SVC_COUNT ))
                ;;
            DOWN)
                selected=$(( (selected + 1) % SVC_COUNT ))
                ;;
            PGUP)
                selected=$(( selected - 5 ))
                [[ $selected -lt 0 ]] && selected=0
                ;;
            PGDN)
                selected=$(( selected + 5 ))
                [[ $selected -ge $SVC_COUNT ]] && selected=$((SVC_COUNT-1))
                ;;
            SPACE)
                toggle_service "$selected"
                ;;
            i|I)
                # limpa tudo (exceto obrigatórios) e seleciona só IoT
                for ((i=0; i<SVC_COUNT; i++)); do
                    [[ ${SVC_MANDATORY[$i]} -eq 1 ]] && continue
                    SVC_SELECTED[$i]=0
                done
                mark_group "IoT" 1
                ;;
            m|M)
                # limpa tudo (exceto obrigatórios) e seleciona só MES
                for ((i=0; i<SVC_COUNT; i++)); do
                    [[ ${SVC_MANDATORY[$i]} -eq 1 ]] && continue
                    SVC_SELECTED[$i]=0
                done
                mark_group "MES" 1
                ;;
            t|T)
                for ((i=0; i<SVC_COUNT; i++)); do
                    SVC_SELECTED[$i]=1
                done
                ;;
            c|C)
                for ((i=0; i<SVC_COUNT; i++)); do
                    [[ ${SVC_MANDATORY[$i]} -eq 1 ]] && continue
                    SVC_SELECTED[$i]=0
                done
                ;;
            ENTER)
                running=0
                ;;
            b)
                running=0
                key="BACK"
                ;;
            QUIT|ESC)
                running=0
                key="QUIT"
                ;;
        esac
    done

    _tui_cleanup
    trap - EXIT INT TERM WINCH

    local result
    result=$(get_selected_services)

    if [[ "$key" == "QUIT" ]]; then
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
    elif [[ -n "${RESULT_FILE:-}" ]]; then
        echo "$result" > "$RESULT_FILE"
    else
        echo "$result"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_screen_services
fi
