#!/usr/bin/env bash
# =============================================================================
# metrics-server-tls-fix.sh
#
# Detecta erros x509 de TLS nos logs do metrics-server durante o scrape do
# kubelet e aplica automaticamente --kubelet-insecure-tls via kubectl patch.
#
# Uso (sourced — integração com install.sh):
#   source ./tools/metrics-server-tls-fix.sh
#   metrics_server_detect_and_fix_tls [namespace] [deployment] [max_wait_secs]
#
# Uso (execução direta):
#   ./tools/metrics-server-tls-fix.sh [namespace] [deployment] [max_wait_secs]
#
# Defaults:
#   namespace      = kube-system
#   deployment     = metrics-server
#   max_wait_secs  = 180
#
# Saída (exit codes):
#   0  — Sem ação necessária (já corrigido / healthy) OU patch aplicado com sucesso
#   1  — Erro fatal (deployment não encontrado, selector inválido)
#   2  — Timeout: janela de observação expirou sem resolução
#
# Constraints atendidas:
#   ✔  Pod pode restartar durante leitura de logs — timeout + || true evitam trava
#   ✔  Rolling update gera 2 pods em paralelo — todos os pods do selector são escaneados
#   ✔  Idempotente — verifica presença do flag antes de aplicar (dupla checagem)
#   ✔  Agnóstico ao tipo de cluster — apenas kubectl puro, sem CLI específico
# =============================================================================

# ---------------------------------------------------------------------------
# Configuráveis (sem readonly para permitir override ao sourcear)
# ---------------------------------------------------------------------------
_MS_X509_PATTERN="x509: cannot validate certificate for"
_MS_LOG_TIMEOUT=20     # segundos máximos por chamada 'kubectl logs' (atual)
_MS_PREV_TIMEOUT=10    # segundos máximos por chamada 'kubectl logs --previous'
_MS_POLL_INTERVAL=10   # segundos entre ciclos de scan

# ---------------------------------------------------------------------------
# _ms_log <level> <msg>   — output de diagnóstico unificado
# ---------------------------------------------------------------------------
_ms_log() {
  local level="$1"; shift
  case "$level" in
    INFO)  printf "\033[1;34m[metrics-server]\033[0m %s\n" "$*"    ;;
    OK)    printf "\033[1;32m[metrics-server]\033[0m %s\n" "$*"    ;;
    WARN)  printf "\033[1;33m[metrics-server]\033[0m %s\n" "$*" >&2 ;;
    ERROR) printf "\033[1;31m[metrics-server]\033[0m %s\n" "$*" >&2 ;;
  esac
}

# ---------------------------------------------------------------------------
# _ms_is_patched <namespace> <deployment>
# Retorna 0 se --kubelet-insecure-tls já está nos args do container.
# ---------------------------------------------------------------------------
_ms_is_patched() {
  kubectl get deployment "$2" -n "$1" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' \
    2>/dev/null | grep -qF 'kubelet-insecure-tls'
}

# ---------------------------------------------------------------------------
# _ms_selector <namespace> <deployment>
# Emite o matchLabels como string de selector compatível com kubectl -l.
# Ex: "app.kubernetes.io/name=metrics-server"
# ---------------------------------------------------------------------------
_ms_selector() {
  kubectl get deployment "$2" -n "$1" \
    -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' \
    2>/dev/null | sed 's/,$//'
}

# ---------------------------------------------------------------------------
# _ms_list_pods <namespace> <selector>
# Emite os nomes dos pods atuais (um por linha) que casam com o selector.
# Never fails — || true garante que erros de API não quebrem o loop.
# ---------------------------------------------------------------------------
_ms_list_pods() {
  kubectl get pods -n "$1" -l "$2" \
    --no-headers \
    -o custom-columns='NAME:.metadata.name' \
    2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _ms_pod_has_x509 <namespace> <pod>
# Escaneia logs atuais E anteriores (--previous) de um único pod.
# Nunca bloqueia mais que _MS_LOG_TIMEOUT + _MS_PREV_TIMEOUT segundos.
# Retorna 0 se o padrão x509 for encontrado, 1 caso contrário.
# ---------------------------------------------------------------------------
_ms_pod_has_x509() {
  local ns="$1" pod="$2"
  local out

  # --- logs do container atual -----------------------------------------------
  # 'timeout' impede trava caso o pod seja Pending/não responsivo.
  # '|| true' garante que timeout ou falha de API não abortem o script.
  out=$(timeout "$_MS_LOG_TIMEOUT" \
        kubectl logs "$pod" -n "$ns" --tail=300 2>&1) || true

  if echo "$out" | grep -qF "$_MS_X509_PATTERN"; then
    return 0
  fi

  # --- logs do container anterior (restart / CrashLoopBackOff) ---------------
  local prev
  prev=$(timeout "$_MS_PREV_TIMEOUT" \
         kubectl logs "$pod" -n "$ns" --previous --tail=300 2>&1) || true

  if echo "$prev" | grep -qF "$_MS_X509_PATTERN"; then
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# _ms_any_pod_has_x509 <namespace> <selector>
# Itera sobre TODOS os pods atuais (lida com rolling update de 2 pods).
# Retorna 0 se qualquer pod contiver o padrão x509, 1 caso contrário.
# ---------------------------------------------------------------------------
_ms_any_pod_has_x509() {
  local ns="$1" selector="$2"

  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue

    if _ms_pod_has_x509 "$ns" "$pod"; then
      _ms_log INFO "Erro x509 encontrado nos logs do pod: $pod"
      return 0
    fi
  done < <(_ms_list_pods "$ns" "$selector")

  return 1
}

# ---------------------------------------------------------------------------
# _ms_is_healthy <namespace> <deployment>
# Retorna 0 quando readyReplicas == spec.replicas > 0.
# Indica que o deployment convergiu sem necessidade de patch.
# ---------------------------------------------------------------------------
_ms_is_healthy() {
  local ns="$1" deploy="$2"
  local ready desired

  # readyReplicas fica ausente (campo vazio) quando 0 pods estão prontos
  ready=$(kubectl get deployment "$deploy" -n "$ns" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  desired=$(kubectl get deployment "$deploy" -n "$ns" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)

  [[ -n "$ready" && -n "$desired" && "$desired" -gt 0 && "$ready" -eq "$desired" ]]
}

# ---------------------------------------------------------------------------
# _ms_apply_patch <namespace> <deployment>
# Aplica JSON patch para ADICIONAR --kubelet-insecure-tls ao array de args
# (op "add" com path "/-" — append seguro, sem sobrescrever outros args).
# Aguarda a conclusão do rolling update antes de retornar.
# ---------------------------------------------------------------------------
_ms_apply_patch() {
  local ns="$1" deploy="$2"

  # Guarda contra race condition (ex.: dois processos rodando em paralelo)
  if _ms_is_patched "$ns" "$deploy"; then
    _ms_log INFO "Flag já presente — patch ignorado (guard de concorrência)."
    return 0
  fi

  _ms_log INFO "Aplicando JSON patch em deployment/$deploy..."
  _ms_log INFO "  op=add  path=/spec/template/spec/containers/0/args/-"
  _ms_log INFO "  value=--kubelet-insecure-tls"

  kubectl patch deployment "$deploy" -n "$ns" \
    --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

  # Rolling update: o pod problemático termina sozinho quando o novo ficar Ready.
  # kubectl rollout status bloqueia até que readyReplicas == desiredReplicas.
  _ms_log INFO "Aguardando rolling update (pod antigo termina → novo pod Ready)..."
  if kubectl rollout status "deployment/$deploy" -n "$ns" --timeout=120s; then
    _ms_log OK "Rollout concluído. metrics-server rodando com --kubelet-insecure-tls."
  else
    _ms_log WARN "Timeout no rollout. Verifique manualmente: kubectl rollout status deployment/$deploy -n $ns"
    return 1
  fi
}

# ===========================================================================
# metrics_server_detect_and_fix_tls [namespace] [deployment] [max_wait_secs]
#
# Ponto de entrada principal. Observa os logs do metrics-server dentro da
# janela de tempo definida e aplica o patch se o erro x509 for detectado.
# ===========================================================================
metrics_server_detect_and_fix_tls() {
  local ns="${1:-kube-system}"
  local deploy="${2:-metrics-server}"
  local max_wait="${3:-180}"

  _ms_log INFO "── Autofix Watch ──────────────────────────────────────────"
  _ms_log INFO "namespace=${ns}  deployment=${deploy}  janela=${max_wait}s"
  _ms_log INFO "Padrão monitorado: \"${_MS_X509_PATTERN}\""

  # --- Pré-condições ---------------------------------------------------------

  if ! kubectl get deployment "$deploy" -n "$ns" &>/dev/null; then
    _ms_log ERROR "deployment/$deploy não encontrado no namespace '$ns'."
    return 1
  fi

  # Idempotência: sai imediatamente se o flag já está presente
  if _ms_is_patched "$ns" "$deploy"; then
    _ms_log OK "--kubelet-insecure-tls já presente nos args. Nada a fazer."
    return 0
  fi

  # Resolve o selector de pods a partir do spec do deployment
  local selector
  selector=$(_ms_selector "$ns" "$deploy")
  if [[ -z "$selector" ]]; then
    _ms_log ERROR "Não foi possível resolver o pod selector de '$deploy'."
    return 1
  fi
  _ms_log INFO "Pod selector: $selector"

  # --- Loop de observação ----------------------------------------------------

  local deadline cycle=0
  deadline=$(( $(date +%s) + max_wait ))

  while (( $(date +%s) < deadline )); do
    cycle=$(( cycle + 1 ))
    local remaining=$(( deadline - $(date +%s) ))
    _ms_log INFO "Ciclo #${cycle} — ${remaining}s restantes na janela"

    # Escaneia TODOS os pods atuais (inclusive o pod antigo durante rolling update)
    if _ms_any_pod_has_x509 "$ns" "$selector"; then
      _ms_apply_patch "$ns" "$deploy"
      return $?
    fi

    # Saída antecipada: deployment está saudável sem erros TLS
    if _ms_is_healthy "$ns" "$deploy"; then
      _ms_log OK "Deployment saudável (todas as réplicas prontas) — patch TLS não necessário."
      return 0
    fi

    _ms_log INFO "Sem erro x509 detectado. Pods ainda não totalmente prontos."
    _ms_log INFO "Próximo scan em ${_MS_POLL_INTERVAL}s..."
    sleep "$_MS_POLL_INTERVAL"
  done

  # --- Timeout ---------------------------------------------------------------

  _ms_log WARN "Janela de ${max_wait}s expirou sem resolução."
  _ms_log WARN "Estado atual do deployment:"
  kubectl get deployment "$deploy" -n "$ns" 2>&1 | sed 's/^/  /' >&2
  _ms_log WARN "Pods correspondentes ao selector:"
  kubectl get pods -n "$ns" -l "$selector" 2>&1 | sed 's/^/  /' >&2
  return 2
}

# ---------------------------------------------------------------------------
# Execução direta (não sourced)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  metrics_server_detect_and_fix_tls "$@"
fi
