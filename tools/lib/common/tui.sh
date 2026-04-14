#!/usr/bin/env bash
# tools/lib/common/tui.sh
# Biblioteca TUI full-screen em bash puro + tput.
# Zero dependências além de bash 4+ e tput (ncurses).
# Em bash < 4 ou terminal sem suporte, cai para menu numerado simples.

# ── Globals ─────────────────────────────────────────────────────────────────
TUI_COLS=80
TUI_LINES=24
TUI_RESIZE=0
TUI_PLAIN=0          # 1 = fallback menu numerado

# Tamanho mínimo do terminal para a TUI (evita distorção de layout)
TUI_MIN_COLS=160
TUI_MIN_LINES=40

# Contextos carregados de kubectl
declare -a CTX_NAMES=()
declare -a CTX_CLUSTERS=()
declare -a CTX_USERS=()
declare -a CTX_NAMESPACES=()
declare -a CTX_SERVERS=()
declare -a CTX_CURRENT=()
CTX_COUNT=0
CURRENT_CTX=""
LAST_CTX_SELECTION=""      # Armazena a última seleção do usuário para preservar ao voltar

# Header configurável por cada tela
HEADER_SUBTITLE="Use as setas para navegar e ENTER para selecionar"
HEADER_CTX=""     # quando preenchido, exibe breadcrumb na linha 2
HEADER_HEIGHT=2   # linhas usadas pelo draw_header (2 ou 3)

# Menu genérico (usado por telas que não são a de contexto)
MENU_COUNT=0
declare -a MENU_ITEMS=()
declare -a MENU_VALUES=()

# Componentes de infraestrutura instalados pelo fluxo real do installer.
declare -a INFRA_COMPONENTS=(
    "metrics-server" "cert-manager" "istio-system" "istio-ingress" "aspire"
    "mongodb" "postgresql" "redis" "keycloak" "rabbitmq" "vernemq"
)
INFRA_COUNT=${#INFRA_COMPONENTS[@]}

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# ── Compatibilidade ──────────────────────────────────────────────────────────
tui_check_compat() {
    # bash < 4: sem arrays associativos, read -t decimal inconsistente
    if [[ "${BASH_VERSINFO[0]:-3}" -lt 4 ]]; then
        TUI_PLAIN=1
        return
    fi
    # Sem TERM ou tput não funcional
    if [[ -z "${TERM:-}" ]] || ! tput cup 0 0 &>/dev/null; then
        TUI_PLAIN=1
        return
    fi
    # Terminal muito pequeno: não define TUI_PLAIN aqui — tui_wait_min_size()
    # cuida disso com tela de orientação ao usuário.
    TUI_COLS=$(tput cols 2>/dev/null || echo 80)
    TUI_LINES=$(tput lines 2>/dev/null || echo 24)
    # Git Bash / MSYS2: tput é significativamente mais lento (fork + ConPTY overhead)
    # As otimizações de escape sequences diretas mitigam isso, mas warnamos o usuário.
    if [[ -n "${MSYSTEM:-}" ]]; then
        if [[ -z "${TUI_GITBASH_WARNED:-}" ]]; then
            warning "Git Bash/MSYS2 detectado. A TUI pode ter performance reduzida."
            warning "Para melhor experiência, considere usar WSL2 ou um terminal Linux/macOS nativo."
            TUI_GITBASH_WARNED=1
        fi
    fi
}

# ── Init / Cleanup ───────────────────────────────────────────────────────────
tui_init() {
    _TUI_ALTSCREEN=""
    if tput smcup &>/dev/null; then
        _TUI_ALTSCREEN=1
    else
        tput clear 2>/dev/null || true
    fi
    tput civis 2>/dev/null || true
    stty -echo 2>/dev/null || true
    tput clear 2>/dev/null || true
    TUI_COLS=$(tput cols 2>/dev/null || echo 80)
    TUI_LINES=$(tput lines 2>/dev/null || echo 24)
    trap '_tui_cleanup' EXIT INT TERM
    trap 'TUI_RESIZE=1' WINCH
}

_tui_cleanup() {
    if [ -t 1 ]; then
        tput cnorm 2>/dev/null || true
        if [ -n "${_TUI_ALTSCREEN:-}" ]; then
            tput rmcup 2>/dev/null || true
        else
            printf '\033[2J\033[H'
        fi
    fi
    stty echo 2>/dev/null || true
}

# ── Leitura de tecla ─────────────────────────────────────────────────────────
read_key() {
    local k k2 k3 rest
    local _debounce=0 _deb_nc=0 _deb_nl=0 _deb_cycles=0

    while true; do
        IFS= read -rsn1 -t 0.15 k 2>/dev/null && break

        local nc nl
        nc=$(tput cols 2>/dev/null || echo 80)
        nl=$(tput lines 2>/dev/null || echo 24)
        if [[ $nc -ne $TUI_COLS || $nl -ne $TUI_LINES ]]; then
            if [[ $_debounce -eq 1 ]] && [[ $nc -eq $_deb_nc && $nl -eq $_deb_nl ]]; then
                TUI_COLS=$nc; TUI_LINES=$nl
                _debounce=0; _deb_cycles=0
                echo "RESIZE"; return 0
            fi
            _deb_cycles=$(( _deb_cycles + 1 ))
            if [[ $_deb_cycles -ge 6 ]]; then
                TUI_COLS=$nc; TUI_LINES=$nl
                _debounce=0; _deb_cycles=0
                echo "RESIZE"; return 0
            fi
            _debounce=1; _deb_nc=$nc; _deb_nl=$nl
        else
            _debounce=0; _deb_cycles=0
        fi
    done

    # Em alguns terminais, ENTER pode chegar como byte vazio com read -n1.
    [[ -z "$k" ]] && { echo "ENTER"; return 0; }

    if [[ "$k" == $'\033' ]]; then
        # Sequencias CSI/SS3 (setas, PgUp/PgDn). Evita vazar 'A'/'B' como tecla comum.
        # Se a sequencia vier incompleta/atrasada, nao fechar a UI por engano.
        IFS= read -rsn1 -t 0.1 k2 2>/dev/null || { echo "UNKNOWN"; return 0; }
        if [[ "$k2" == "[" || "$k2" == "O" ]]; then
            IFS= read -rsn1 -t 0.1 k3 2>/dev/null || { echo "UNKNOWN"; return 0; }
            case "$k3" in
                A) echo "UP"; return 0 ;;
                B) echo "DOWN"; return 0 ;;
                C) echo "RIGHT"; return 0 ;;
                D) echo "LEFT"; return 0 ;;
                F) echo "END"; return 0 ;;
                H) echo "HOME"; return 0 ;;
                M) echo "ENTER"; return 0 ;;
                5|6)
                    # Espera '~' de PgUp/PgDn
                    IFS= read -rsn1 -t 0.05 rest 2>/dev/null || true
                    if [[ "$k3" == "5" && "$rest" == "~" ]]; then
                        echo "PGUP"; return 0
                    elif [[ "$k3" == "6" && "$rest" == "~" ]]; then
                        echo "PGDN"; return 0
                    fi
                    ;;
            esac
            # Sequencia ANSI desconhecida: ignora sem encerrar a interface.
            echo "UNKNOWN"
            return 0
        fi
        # ESC seguido de byte nao reconhecido: nao trata como sair.
        echo "UNKNOWN"
        return 0
    fi
    case "$k" in
        $'\r'|$'\n')       echo "ENTER" ;;
        $' ')                echo "SPACE"  ;;
        q|Q)                 echo "QUIT"  ;;
        *)                   echo "$k" ;;
    esac
}

tui_on_resize() {
    TUI_COLS=$(tput cols 2>/dev/null || echo 80)
    TUI_LINES=$(tput lines 2>/dev/null || echo 24)
    printf '\033[2J\033[H'
}

# Aguarda o terminal atingir o tamanho mínimo.
# Retorna 0 se o tamanho foi atingido, 1 se o usuário escolheu modo texto.
tui_wait_min_size() {
    local cols lines
    cols=$(tput cols 2>/dev/null || echo 80)
    lines=$(tput lines 2>/dev/null || echo 24)

    if [[ $cols -ge $TUI_MIN_COLS && $lines -ge $TUI_MIN_LINES ]]; then
        TUI_COLS=$cols
        TUI_LINES=$lines
        return 0
    fi

    while [[ $cols -lt $TUI_MIN_COLS || $lines -lt $TUI_MIN_LINES ]]; do
        printf '\033[2J\033[H'
        printf '\033[1m=== PlantSuite Kubernetes Installer ===\033[0m\n\n'
        printf '\033[1;31mTerminal muito pequeno!\033[0m\n\n'
        printf '  Tamanho atual   : %dx%d\n' "$cols" "$lines"
        printf '  Minimo necessario: %dx%d\n\n' "$TUI_MIN_COLS" "$TUI_MIN_LINES"
        printf 'Redimensione a janela do terminal para continuar.\n'
        printf 'Aperte \033[1m q \033[0m para usar o modo texto.\n'

        # Espera por input ou redimensionamento
        local key
        IFS= read -rsn1 -t 1 key 2>/dev/null || true
        if [[ "$key" == "q" || "$key" == "Q" ]]; then
            TUI_PLAIN=1
            return 1
        fi

        cols=$(tput cols 2>/dev/null || echo 80)
        lines=$(tput lines 2>/dev/null || echo 24)
    done

    TUI_COLS=$cols
    TUI_LINES=$lines
    return 0
}

# ── Cores ────────────────────────────────────────────────────────────────────
C_RESET=""
C_TITLE=""
C_SELECTED=""
C_DIM=""
C_ACCENT=""
C_WARN=""
C_ERROR=""
C_SUCCESS=""

tui_init_colors() {
    local ncolors
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [[ $ncolors -ge 8 ]]; then
        C_RESET=$(tput sgr0)
        C_TITLE=$(tput bold; tput setaf 2)              # verde bold
        C_SELECTED=$(tput setaf 0; tput setab 2)        # preto/verde
        C_DIM=$(tput setaf 7)                           # branco suave
        C_ACCENT=$(tput setaf 6)                        # ciano
        C_WARN=$(tput setaf 3)                          # amarelo
        C_ERROR=$(tput setaf 1)                         # vermelho
        C_SUCCESS=$(tput setaf 2)                       # verde
    fi
}

# ── Texto ────────────────────────────────────────────────────────────────────
# Trunca texto em N chars, adiciona ... se necessário
trunc() {
    local t="$1" n="${2:-80}"
    if [[ ${#t} -le $n ]]; then printf '%s' "$t"; return; fi
    if [[ $n -le 3 ]]; then printf '%s' "${t:0:$n}"; return; fi
    printf '%s' "${t:0:$((n-3))}..."
}

# ── Escape sequences (substituem tput cup/el para evitar forks) ──────────────
# Move cursor para linha/coluna (0-indexed)
_tui_move_cursor() {
    local row="$1" col="$2"
    printf '\033[%d;%dH' "$((row+1))" "$((col+1))"
}

# Limpa do cursor até o final da linha
_tui_clear_eol() {
    printf '\033[K'
}

# Gera string de N hífens sem subshell
_tui_dashes() {
    local count="$1"
    printf "%0.s-" $(seq 1 "$count" 2>/dev/null | tr -d '\n' || true)
}

# Coloriza legenda de atalhos: chave em C_ACCENT, descrição em C_DIM.
# Segmentos separados por ≥3 espaços; chave = token antes do 1º espaço ou '='.
colorize_hint() {
    local plain="$1" result="$C_DIM" state=0 spaces=0 i c
    for ((i=0; i<${#plain}; i++)); do
        c="${plain:$i:1}"
        case $state in
            0) # entre segmentos: espaços passam, qualquer outro char inicia chave
                if [[ "$c" == " " ]]; then result+="$c"
                else result+="${C_ACCENT}${c}"; state=1; fi ;;
            1) # na chave: espaço ou '=' encerra a chave, inicia descrição
                if [[ "$c" == " " || "$c" == "=" ]]; then
                    result+="${C_DIM}${c}"
                    if [[ "$c" == " " ]]; then spaces=1; else spaces=0; fi
                    state=2
                else result+="$c"; fi ;;
            2) # na descrição: ≥3 espaços consecutivos voltam ao estado 0
                if [[ "$c" == " " ]]; then
                    spaces=$((spaces + 1))
                    result+="$c"
                    if [[ $spaces -ge 3 ]]; then state=0; spaces=0; fi
                else spaces=0; result+="$c"; fi ;;
        esac
    done
    printf '%s%s' "$result" "$C_RESET"
}

# Imprime em posição (linha col), truncando à largura disponível
at() {
    local row="$1" col="$2" text="$3" attr="${4:-}" maxw="${5:-}"
    [[ -z "$maxw" ]] && maxw=$((TUI_COLS - col - 1))
    [[ $maxw -le 0 ]] && return 0
    _tui_move_cursor "$row" "$col"
    [[ -n "$attr" ]] && printf '%s' "$attr"
    printf '%s' "$(trunc "$text" "$maxw")"
    [[ -n "$attr" ]] && printf '%s' "$C_RESET"
}

# Limpa 'width' caracteres a partir de 'col' na 'row'
clear_area() {
    local row="$1" col="$2" width="$3"
    _tui_move_cursor "$row" "$col"
    printf '%*s' "$width" ''
}

has_kustomization_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    [[ -f "$dir/kustomization.yaml" || -f "$dir/kustomization.yml" || -f "$dir/Kustomization" ]]
}

infra_source_for_overlay() {
    local component="$1"
    local overlay="${2:-${SELECTED_OVERLAY:-}}"

    if [[ -z "$overlay" || "$overlay" == "base" ]]; then
        echo "base"
        return
    fi

    if has_kustomization_dir "$INSTALLER_ROOT/k8s/overlays/$overlay/$component"; then
        echo "overlay"
    else
        echo "base"
    fi
}

# ── Caixa ASCII ──────────────────────────────────────────────────────────────
# draw_box row col height width [title]
draw_box() {
    local row="$1" col="$2" h="$3" w="$4" title="${5:-}"
    [[ $h -lt 3 || $w -lt 4 ]] && return 0
    local inner=$((w - 2))
    local r c
    # Topo
    _tui_move_cursor "$row" "$col"
    printf '%s+' "$C_DIM"
    if [[ -n "$title" ]]; then
        local t=" $title "
        local tl=${#t}
        local fill=$((inner - tl))
        [[ $fill -lt 0 ]] && { t="${t:0:$inner}"; fill=0; }
        printf '%s' "$t"
        if [[ $fill -gt 0 ]]; then
            local dashes="" 
            printf -v dashes '%*s' "$fill" ''
            printf '%s' "${dashes// /-}"
        fi
    else
        local dashes=""
        printf -v dashes '%*s' "$inner" ''
        printf '%s' "${dashes// /-}"
    fi
    printf '+%s' "$C_RESET"
    # Laterais
    for ((r=row+1; r<row+h-1; r++)); do
        _tui_move_cursor "$r" "$col"
        printf '%s|%s' "$C_DIM" "$C_RESET"
        _tui_move_cursor "$r" "$((col+w-1))"
        printf '%s|%s' "$C_DIM" "$C_RESET"
    done
    # Base
    _tui_move_cursor "$((row+h-1))" "$col"
    printf '%s+' "$C_DIM"
    local dashes=""
    printf -v dashes '%*s' "$inner" ''
    printf '%s' "${dashes// /-}"
    printf '+%s' "$C_RESET"
}

# ── Cabeçalho e rodapé compartilhados ────────────────────────────────────────
LAYOUT_NAME="PlantSuite"

draw_header() {
    local title="PlantSuite Kubernetes Installer"
    local title_banner="*** ${title} ***"
    local title_col=$(( (TUI_COLS - ${#title_banner}) / 2 ))
    [[ $title_col -lt 0 ]] && title_col=0

    _tui_move_cursor 0 0
    _tui_clear_eol
    at 0 "$title_col" "$title_banner" "$C_TITLE"

    local subtitle_col=$(( (TUI_COLS - ${#HEADER_SUBTITLE}) / 2 ))
    [[ $subtitle_col -lt 0 ]] && subtitle_col=0
    _tui_move_cursor 1 0
    _tui_clear_eol
    _tui_move_cursor 2 0
    _tui_clear_eol
    at 2 "$subtitle_col" "$(trunc "$HEADER_SUBTITLE" $((TUI_COLS - 4)))" "$C_DIM"

    if [[ -n "$HEADER_CTX" ]]; then
        local ctx="$HEADER_CTX"
        local ctx_col=$(( (TUI_COLS - ${#ctx}) / 2 ))
        [[ $ctx_col -lt 0 ]] && ctx_col=0
        _tui_move_cursor 3 0
        _tui_clear_eol
        at 3 "$ctx_col" "$(trunc "$ctx" $((TUI_COLS - 4)))" "$C_ACCENT"
        _tui_move_cursor 4 0
        _tui_clear_eol
        HEADER_HEIGHT=4
    else
        _tui_move_cursor 3 0
        _tui_clear_eol
        HEADER_HEIGHT=3
    fi
}

draw_footer() {
    local msg="${1:-}"
    local hint="  ↑↓ navegar   enter selecionar   q sair  "
    _tui_move_cursor "$((TUI_LINES - 1))" 0
    _tui_clear_eol
    colorize_hint "$(trunc "$hint" $((TUI_COLS / 2)))"
    if [[ -n "$msg" ]]; then
        at "$((TUI_LINES - 1))" $((TUI_COLS / 2)) "$msg" "$C_ACCENT" $((TUI_COLS / 2 - 2))
    fi
}

# ── Carregamento de contextos kubectl ────────────────────────────────────────
load_contexts() {
    CTX_NAMES=()
    CTX_CLUSTERS=()
    CTX_USERS=()
    CTX_NAMESPACES=()
    CTX_SERVERS=()
    CTX_CURRENT=()
    CTX_COUNT=0

    CURRENT_CTX=$(kubectl config current-context 2>/dev/null || true)

    local names_raw
    names_raw=$(kubectl config view \
        -o jsonpath='{range .contexts[*]}{.name}{"\n"}{end}' 2>/dev/null || true)
    [[ -z "$names_raw" ]] && return

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local cluster user ns server
        cluster=$(kubectl config view \
            -o jsonpath="{.contexts[?(@.name==\"${name}\")].context.cluster}" 2>/dev/null || echo "-")
        user=$(kubectl config view \
            -o jsonpath="{.contexts[?(@.name==\"${name}\")].context.user}" 2>/dev/null || echo "-")
        ns=$(kubectl config view \
            -o jsonpath="{.contexts[?(@.name==\"${name}\")].context.namespace}" 2>/dev/null || true)
        server=$(kubectl config view \
            -o jsonpath="{.clusters[?(@.name==\"${cluster}\")].cluster.server}" 2>/dev/null || echo "-")
        CTX_NAMES+=("$name")
        CTX_CLUSTERS+=("${cluster:--}")
        CTX_USERS+=("${user:--}")
        CTX_NAMESPACES+=("${ns:-default}")
        CTX_SERVERS+=("${server:--}")
        CTX_CURRENT+=( "$( [[ "$name" == "$CURRENT_CTX" ]] && echo 1 || echo 0 )" )
    done <<< "$names_raw"

    CTX_COUNT=${#CTX_NAMES[@]}
}

# Janela de scroll: retorna (top) dado total, selected, capacity
scroll_top() {
    local total="$1" sel="$2" cap="$3"
    local top=$((sel - cap / 2))
    [[ $top -lt 0 ]] && top=0
    [[ $((top + cap)) -gt $total ]] && top=$((total - cap))
    [[ $top -lt 0 ]] && top=0
    echo "$top"
}

# ── Lista navegável (bloco reutilizável) ──────────────────────────────────────
# draw_list row col height width selected
draw_list() {
    local row="$1" col="$2" h="$3" w="$4" sel="$5"
    local cap=$((h))
    local top; top=$(scroll_top "$CTX_COUNT" "$sel" "$cap")
    local i=0
    while [[ $i -lt $cap && $((i+top)) -lt $CTX_COUNT ]]; do
        local idx=$((i+top))
        local name="${CTX_NAMES[$idx]}"
        local cur="${CTX_CURRENT[$idx]}"
        local label="$name"
        [[ "$cur" == "1" ]] && label="$name [atual]"
        _tui_move_cursor "$((row+i))" "$col"
        _tui_clear_eol
        local inner=$((w-2))
        if [[ $idx -eq $sel ]]; then
            printf '%s> %s%s' \
                "$C_SELECTED" \
                "$(trunc "$label" "$((inner-2))")" \
                "$C_RESET"
        else
            printf '  %s' "$(trunc "$label" "$inner")"
        fi
        ((i++)) || true
    done
    # Limpa linhas sobrando
    while [[ $i -lt $cap ]]; do
        _tui_move_cursor "$((row+i))" "$col"
        _tui_clear_eol
        ((i++)) || true
    done
}

# ── Preview de contexto (bloco reutilizável) ──────────────────────────────────
# draw_preview row col height width idx
draw_preview() {
    local row="$1" col="$2" h="$3" w="$4" idx="$5"
    local lines=(
        "Contexto : ${CTX_NAMES[$idx]}"
        "Cluster  : ${CTX_CLUSTERS[$idx]}"
        "Usuario  : ${CTX_USERS[$idx]}"
        "Namespace: ${CTX_NAMESPACES[$idx]}"
        "API      : ${CTX_SERVERS[$idx]}"
    )
    local i=0
    for line in "${lines[@]}"; do
        [[ $i -ge $((h-2)) ]] && break
        at "$((row+i+1))" "$((col+2))" "$(trunc "$line" $((w-4)))"
        ((i++)) || true
    done
}

# ── Fallback: menu numerado simples ──────────────────────────────────────────
run_plain_menu() {
    echo ""
    echo "=== PlantSuite Kubernetes Installer ==="
    echo ""
    if [[ $CTX_COUNT -eq 0 ]]; then
        echo "Nenhum contexto Kubernetes encontrado."
        echo "Verifique o kubeconfig e tente novamente."
        exit 1
    fi

    echo "Contextos disponíveis:"
    local i
    for ((i=0; i<CTX_COUNT; i++)); do
        local cur=""
        [[ "${CTX_CURRENT[$i]}" == "1" ]] && cur=" *"
        printf '  %2d) %s%s\n' "$((i+1))" "${CTX_NAMES[$i]}" "$cur"
    done
    echo ""
    local choice
    while true; do
        read -rp "Digite o número do contexto: " choice
        if [[ "$choice" =~ ^[qQ]$ ]]; then
            if [[ -n "${RESULT_FILE:-}" ]]; then
                echo "__QUIT__" > "$RESULT_FILE"
            else
                echo "__QUIT__"
            fi
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [[ "$choice" -ge 1 && "$choice" -le $CTX_COUNT ]]; then
                local _result="${CTX_NAMES[$((choice-1))]}"
                if [[ -n "${RESULT_FILE:-}" ]]; then
                    echo "$_result" > "$RESULT_FILE"
                else
                    echo "$_result"
                fi
                return 0
        fi
        echo "Opção inválida. Tente novamente."
    done
}

# ── Menu genérico (para telas que não são a de contexto) ────────────────────
# Caller popula MENU_COUNT, MENU_ITEMS, MENU_VALUES e define draw_screen().
# Imprime MENU_VALUES[$selected] no stdout ao confirmar.
run_plain_menu_generic() {
    echo ""
    echo "=== PlantSuite Kubernetes Installer ==="
    [[ -n "$HEADER_CTX" ]] && echo "Contexto: $HEADER_CTX"
    echo ""
    local i
    for ((i=0; i<MENU_COUNT; i++)); do
        printf '  %2d) %s\n' "$((i+1))" "${MENU_ITEMS[$i]}"
    done
    echo ""
    local choice
    while true; do
        read -rp "Digite o número (ou B para voltar): " choice
        if [[ "$choice" =~ ^[qQ]$ ]]; then
            if [[ -n "${RESULT_FILE:-}" ]]; then
                echo "__QUIT__" > "$RESULT_FILE"
            else
                echo "__QUIT__"
            fi
            return 0
        fi
        if [[ "$choice" =~ ^[bB]$ ]]; then
            if [[ -n "${RESULT_FILE:-}" ]]; then
                echo "__BACK__" > "$RESULT_FILE"
            else
                echo "__BACK__"
            fi
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [[ "$choice" -ge 1 && "$choice" -le $MENU_COUNT ]]; then
                local _result="${MENU_VALUES[$((choice-1))]}"
                if [[ -n "${RESULT_FILE:-}" ]]; then
                    echo "$_result" > "$RESULT_FILE"
                else
                    echo "$_result"
                fi
                return 0
        fi
        echo "Opção inválida. Tente novamente."
    done
}

    # ── Descarta input pendente no terminal (evita vazamento de teclas entre telas)
    input_flush() {
        local _d
        while IFS= read -rsn1 -t 0.05 _d 2>/dev/null; do :; done
    }

    run_menu() {
    tui_check_compat
    if [[ $TUI_PLAIN -eq 1 ]]; then
        run_plain_menu_generic
        return
    fi
    if [[ $MENU_COUNT -eq 0 ]]; then
        return 1
    fi
    tui_init
    tui_init_colors
    if ! tui_wait_min_size; then
        _tui_cleanup
        run_plain_menu_generic
        return
    fi
        local selected=0 running=1
        input_flush
    while [[ $running -eq 1 ]]; do
        _tui_move_cursor 0 0
        draw_screen "$selected"
        _tui_move_cursor 0 0

        local key; key=$(read_key) || continue
        case "$key" in
            RESIZE)
                tui_on_resize
                ;;
            UP)    selected=$(( (selected - 1 + MENU_COUNT) % MENU_COUNT )) ;;
            DOWN)  selected=$(( (selected + 1) % MENU_COUNT )) ;;
            PGUP)  selected=$(( selected - 5 )); [[ $selected -lt 0 ]] && selected=0 ;;
            PGDN)  selected=$(( selected + 5 )); [[ $selected -ge $MENU_COUNT ]] && selected=$((MENU_COUNT-1)) ;;
            ENTER) running=0 ;;
            QUIT|ESC) selected=-1; running=0 ;;
            b) selected=-2; running=0 ;;
        esac
    done
    _tui_cleanup
    trap - EXIT INT TERM WINCH
    if [[ $selected -eq -1 ]]; then
        if [[ -n "${RESULT_FILE:-}" ]]; then
            echo "__QUIT__" > "$RESULT_FILE"
        else
            echo "__QUIT__"
        fi
    elif [[ $selected -eq -2 ]]; then
        if [[ -n "${RESULT_FILE:-}" ]]; then
            echo "__BACK__" > "$RESULT_FILE"
        else
            echo "__BACK__"
        fi
    elif [[ $selected -ge 0 ]]; then
        if [[ -n "${RESULT_FILE:-}" ]]; then
            echo "${MENU_VALUES[$selected]}" > "$RESULT_FILE"
        else
            echo "${MENU_VALUES[$selected]}"
        fi
    fi
}

# ── Loop de eventos principal ─────────────────────────────────────────────────
# Chama a função draw_screen (definida pelo layout) e processa teclas.
# Imprime o nome do contexto selecionado no stdout ao confirmar.
run_tui() {
    tui_check_compat
    load_contexts

    if [[ $TUI_PLAIN -eq 1 ]]; then
        run_plain_menu
        return
    fi

    tui_init
    tui_init_colors
    if ! tui_wait_min_size; then
        _tui_cleanup
        run_plain_menu
        return
    fi

    if [[ $CTX_COUNT -eq 0 ]]; then
        tput clear 2>/dev/null || true
        at 2 2 "PlantSuite Kubernetes Installer" "$C_TITLE"
        at 4 2 "Nenhum contexto Kubernetes encontrado em kubectl config view." "$C_WARN"
        at 5 2 "Verifique o kubeconfig e pressione Q para sair."
        at $((TUI_LINES-1)) 2 "Q sair" "$C_DIM"
        while true; do
            local k; k=$(read_key)
            [[ "$k" == "QUIT" || "$k" == "ESC" ]] && break
        done
        return 1
    fi

    # Pré-seleciona: primeiro tenta usar a seleção anterior do usuário,
    # senão usa o contexto atual do kubeconfig
    local selected=0
    if [[ -n "$LAST_CTX_SELECTION" && "$LAST_CTX_SELECTION" -lt $CTX_COUNT ]]; then
        # Usa a seleção anterior do usuário
        selected="$LAST_CTX_SELECTION"
    else
        # Primeira vez ou seleção inválida: usa o contexto atual
        local i
        for ((i=0; i<CTX_COUNT; i++)); do
            if [[ "${CTX_CURRENT[$i]}" == "1" ]]; then
                selected=$i
                break
            fi
        done
    fi
    local running=1

input_flush
    while [[ $running -eq 1 ]]; do
        _tui_move_cursor 0 0
        draw_screen "$selected"
        _tui_move_cursor 0 0

        local key; key=$(read_key) || continue
        case "$key" in
            RESIZE)
                tui_on_resize
                ;;
            UP)
                selected=$(( (selected - 1 + CTX_COUNT) % CTX_COUNT ))
                ;;
            DOWN)
                selected=$(( (selected + 1 + CTX_COUNT) % CTX_COUNT ))
                ;;
            PGUP)
                selected=$(( selected - 10 ))
                [[ $selected -lt 0 ]] && selected=0
                ;;
            PGDN)
                selected=$(( selected + 10 ))
                [[ $selected -ge $CTX_COUNT ]] && selected=$((CTX_COUNT-1))
                ;;
            ENTER)
                running=0
                ;;
            QUIT|ESC)
                selected=-1
                running=0
                ;;
        esac
    done

    _tui_cleanup
    trap - EXIT INT TERM WINCH

    if [[ $selected -eq -1 ]]; then
        if [[ -n "${RESULT_FILE:-}" ]]; then
            echo "__QUIT__" > "$RESULT_FILE"
        else
            echo "__QUIT__"
        fi
    elif [[ $selected -ge 0 ]]; then
        # Salva a seleção do usuário para preservar ao voltar
        LAST_CTX_SELECTION=$selected
        if [[ -n "${RESULT_FILE:-}" ]]; then
            echo "${CTX_NAMES[$selected]}" > "$RESULT_FILE"
        else
            echo "${CTX_NAMES[$selected]}"
        fi
    fi
}
