#!/usr/bin/env bash
# tools/install.sh
# Instalador Kubernetes com UX TUI.
# O fluxo é sempre de instalação (sem detecção de modo).

# Mantemos modo estrito sem `-e` para não encerrar telas interativas
# por retornos não críticos (ex.: leituras de teclado/fallback plain).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/.." && pwd)"
REAL_DIR="$ROOT_DIR/lib"

# Compatibilidade com libs reaproveitadas do install legado.
UPDATE_MODE=false
AUTO_MODE="install"

# Selecoes do modo atualizacao.
UPDATE_SELECTED_INFRA=""
UPDATE_SELECTED_PLANTSUITE_APPLY=""
UPDATE_SELECTED_PLANTSUITE_DELETE=""

klog() {
  printf '[INFO] %s\n' "$*"
}

warning() {
  printf '[WARN] %s\n' "$*" >&2
}

error() {
  printf '[ERRO] %s\n' "$*" >&2
}

cl_printf() {
  printf '\r\033[K%s' "$(printf "$@")"
}

assert_repo_root() {
  if [[ ! -d "$REPO_DIR/k8s" || ! -d "$REPO_DIR/k8s/base" || ! -f "$REPO_DIR/README.md" ]]; then
    printf '\n[ERRO] Execute este script na raiz do repositório.\n\n' >&2
    exit 1
  fi
}

assert_repo_root
cd "$REPO_DIR"

_TMPFILE=$(mktemp)
trap 'rm -f "$_TMPFILE"' EXIT

# Telas de seleção.
source "$REAL_DIR/screen-context.sh"
source "$REAL_DIR/screen-overlay.sh"
source "$REAL_DIR/screen-services.sh"
source "$REAL_DIR/screen-confirmation.sh"
source "$REAL_DIR/screen-update-selection.sh"
source "$REAL_DIR/screen-confirmation-update.sh"
source "$REAL_DIR/screen-discovery.sh"
source "$REAL_DIR/update-detect.sh"

# Núcleo do instalador.
source "$REAL_DIR/pipeline.sh"
source "$REAL_DIR/k8s-adapter.sh"
source "$REAL_DIR/screen-execution-real.sh"

step=1
while true; do
  case "$step" in
    1)
      : > "$_TMPFILE"
      RESULT_FILE="$_TMPFILE" run_screen_context
      SELECTED_CONTEXT=$(cat "$_TMPFILE" 2>/dev/null || true)
      [[ "$SELECTED_CONTEXT" == "__QUIT__" ]] && exit 0
      [[ -z "$SELECTED_CONTEXT" ]] && { printf '\n[INFO] Nenhum contexto selecionado. Abortando.\n\n'; exit 0; }
      export SELECTED_CONTEXT

      if ! kubectl config use-context "$SELECTED_CONTEXT" >/dev/null 2>&1; then
        printf '\n[ERRO] Falha ao trocar para o contexto selecionado: %s\n\n' "$SELECTED_CONTEXT" >&2
        exit 1
      fi

      step=2
      ;;
    2)
      : > "$_TMPFILE"
      RESULT_FILE="$_TMPFILE" run_screen_overlay
      SELECTED_OVERLAY=$(cat "$_TMPFILE" 2>/dev/null || true)
      [[ "$SELECTED_OVERLAY" == "__QUIT__" ]] && exit 0
      if [[ "$SELECTED_OVERLAY" == "__BACK__" ]]; then
        step=1
        continue
      fi
      [[ -z "$SELECTED_OVERLAY" ]] && { printf '\n[INFO] Nenhum overlay selecionado. Abortando.\n\n'; exit 0; }
      export SELECTED_OVERLAY

      : > "$_TMPFILE"
      RESULT_FILE="$_TMPFILE" run_screen_discovery
      AUTO_MODE=$(cat "$_TMPFILE" 2>/dev/null || true)
      [[ "$AUTO_MODE" == "__QUIT__" ]] && exit 0
      [[ -z "$AUTO_MODE" ]] && AUTO_MODE="install"

      if [[ "$AUTO_MODE" == "update" ]]; then
        UPDATE_MODE=true
        step=30
      else
        UPDATE_MODE=false
        step=3
      fi
      ;;
    3)
      : > "$_TMPFILE"
      RESULT_FILE="$_TMPFILE" run_screen_services
      SELECTED_SERVICES=$(cat "$_TMPFILE" 2>/dev/null || true)
      [[ "$SELECTED_SERVICES" == "__QUIT__" ]] && exit 0
      if [[ "$SELECTED_SERVICES" == "__BACK__" ]]; then
        step=2
        continue
      fi
      [[ -z "$SELECTED_SERVICES" ]] && { printf '\n[INFO] Nenhum serviço selecionado. Abortando.\n\n'; exit 0; }
      export SELECTED_SERVICES
      step=4
      ;;
    4)
      : > "$_TMPFILE"
      RESULT_FILE="$_TMPFILE" run_screen_confirmation
      CONFIRMATION=$(cat "$_TMPFILE" 2>/dev/null || true)
      [[ "$CONFIRMATION" == "__QUIT__" ]] && exit 0
      if [[ "$CONFIRMATION" == "__BACK__" ]]; then
        step=3
        continue
      fi
      [[ "$CONFIRMATION" != "confirmed" ]] && { printf '\n[INFO] Instalação cancelada.\n\n'; exit 0; }
      step=5
      ;;
    30)
      : > "$_TMPFILE"
      UPDATE_SELECTED_INFRA=""
      UPDATE_SELECTED_PLANTSUITE_APPLY=""
      UPDATE_SELECTED_PLANTSUITE_DELETE=""
      RESULT_FILE="$_TMPFILE" run_screen_update_selection
      UPDATE_SELECTION_RESULT=$(cat "$_TMPFILE" 2>/dev/null || true)
      [[ "$UPDATE_SELECTION_RESULT" == "__QUIT__" ]] && exit 0
      if [[ "$UPDATE_SELECTION_RESULT" == "__BACK__" ]]; then
        step=2
        continue
      fi

      if [[ -z "$UPDATE_SELECTED_INFRA" && -z "$UPDATE_SELECTED_PLANTSUITE_APPLY" && -z "$UPDATE_SELECTED_PLANTSUITE_DELETE" ]]; then
        # Fallback: parse resiliente do arquivo/string de retorno da tela.
        while IFS='=' read -r key value; do
          value="${value%$'\r'}"
          case "$key" in
            APPLY_INFRA) UPDATE_SELECTED_INFRA="$value" ;;
            APPLY_SERVICES) UPDATE_SELECTED_PLANTSUITE_APPLY="$value" ;;
            DELETE_SERVICES) UPDATE_SELECTED_PLANTSUITE_DELETE="$value" ;;
          esac
        done < "$_TMPFILE"

        if [[ -z "$UPDATE_SELECTED_INFRA" && -z "$UPDATE_SELECTED_PLANTSUITE_APPLY" && -z "$UPDATE_SELECTED_PLANTSUITE_DELETE" && "$UPDATE_SELECTION_RESULT" == *"APPLY_"* ]]; then
          while IFS='=' read -r key value; do
            value="${value%$'\r'}"
            case "$key" in
              APPLY_INFRA) UPDATE_SELECTED_INFRA="$value" ;;
              APPLY_SERVICES) UPDATE_SELECTED_PLANTSUITE_APPLY="$value" ;;
              DELETE_SERVICES) UPDATE_SELECTED_PLANTSUITE_DELETE="$value" ;;
            esac
          done <<< "$UPDATE_SELECTION_RESULT"
        fi
      fi

      export UPDATE_SELECTED_INFRA
      export UPDATE_SELECTED_PLANTSUITE_APPLY
      export UPDATE_SELECTED_PLANTSUITE_DELETE

      if [[ -z "$UPDATE_SELECTED_INFRA" && -z "$UPDATE_SELECTED_PLANTSUITE_APPLY" && -z "$UPDATE_SELECTED_PLANTSUITE_DELETE" ]]; then
        printf '\n[INFO] Nenhuma ação de atualização selecionada. Voltando para a seleção.\n\n'
        step=30
        continue
      fi

      step=32
      ;;
    32)
      : > "$_TMPFILE"
      RESULT_FILE="$_TMPFILE" run_screen_update_confirmation
      CONFIRMATION=$(cat "$_TMPFILE" 2>/dev/null || true)
      [[ "$CONFIRMATION" == "__QUIT__" ]] && exit 0
      if [[ "$CONFIRMATION" == "__BACK__" ]]; then
        step=30
        continue
      fi
      [[ "$CONFIRMATION" != "confirmed" ]] && { printf '\n[INFO] Atualização cancelada.\n\n'; exit 0; }
      step=5
      ;;
    5)
      : > "$_TMPFILE"
      RESULT_FILE="$_TMPFILE" run_screen_execution_real
      EXEC_RESULT=$(cat "$_TMPFILE" 2>/dev/null || true)
      [[ "$EXEC_RESULT" == "__QUIT__" ]] && exit 0
      if [[ "$EXEC_RESULT" == "canceled" ]]; then
        exit 0
      fi
      if [[ "$EXEC_RESULT" == "failed" ]]; then
        if [[ "$UPDATE_MODE" == "true" ]]; then
          printf '\n[ERRO] Atualização finalizada com erro.\n\n' >&2
        else
          printf '\n[ERRO] Instalação finalizada com erro.\n\n' >&2
        fi
        exit 1
      fi
      break
      ;;
  esac
done

printf '\n%s' "$(tput bold 2>/dev/null || true)$(tput setaf 2 2>/dev/null || true)"
if [[ "$UPDATE_MODE" == "true" ]]; then
  printf '✓ Atualização finalizada com sucesso.\n'
else
  printf '✓ Instalação finalizada com sucesso.\n'
fi
printf '%s\n\n' "$(tput sgr0 2>/dev/null || true)"
printf '  Contexto : %s\n' "$SELECTED_CONTEXT"
printf '  Overlay  : %s\n\n' "$SELECTED_OVERLAY"
