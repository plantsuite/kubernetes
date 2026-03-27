#!/bin/sh
# =============================================================================
# redis-healer.sh — Sidecar de saúde do Redis Cluster com eleição de líder via Lease K8s
# =============================================================================
# Executa ao lado do container redis em cada pod da StatefulSet.
# Todos os sidecars executam verificações de saúde locais. Apenas o líder executa
# verificações em nível de cluster e ações de auto-reparo conservativo.
#
# Política de auto-reparo (CONSERVATIVA):
#   TIER 1  — todos sidecars: exporta métricas, emite eventos K8s
#   TIER 2  — somente líder, cluster_state=ok, sem falha multi-pod:
#               CLUSTER FORGET nós stale (>5min offline, não é master ativo)
#               CLUSTER REPLICATE link replica broken (>2min offline)
#               CLUSTER MEET peer faltando na topologia
#   NUNCA   — CLUSTER RESET, cluster create, add-node, del-node, reshard,
#              pod delete, nenhuma escrita em nodes.conf
# =============================================================================

set -e

# ---------------------------------------------------------------------------
# Ambiente
# ---------------------------------------------------------------------------
. /shared/replicas.env 2>/dev/null || REPLICAS=6

# Guard para modo standalone: redis-healer não é applicable sem cluster
if [ "${REPLICAS}" -eq "1" ]; then
  echo "[healer] Standalone mode detected (REPLICAS=1) — redis-healer not applicable."
  echo "[healer] Entering standby mode (sleeping indefinitely)..."
  # Não fazer exit 0 — container precisa continuar rodando para evitar restart loop
  # Em modo standalone, não há healing operations, apenas sleep
  while true; do
    sleep 3600  # Sleep 1 hora por vez
  done
fi

SERVICENAME=$(echo "${HOSTNAME}" | rev | cut -d'-' -f2- | rev)
ORDINAL=$(echo "${HOSTNAME}" | rev | cut -d'-' -f1 | rev)
PRIMARIES=$(( (REPLICAS + 1) / 2 ))
LEASE_NAME="redis-cluster-healer"
LEASE_DURATION=30
RENEW_INTERVAL=10
# kubectl copiado pelo init container get-replicas — imagem redis:alpine não inclui kubectl
KUBECTL_BIN="/shared/kubectl"

# Arquivos de estado em memoria (tmpfs — sem PVC)
STALE_FIRST_SEEN="/tmp/stale_first_seen"
LAST_FORGET_TIME="/tmp/last_forget_time"
LAST_REPLICATE_TIME="/tmp/last_replicate_time"
LAST_MEET_TIME="/tmp/last_meet_time"
REPL_LINK_DOWN_SINCE="/tmp/repl_link_down_since"
METRICS_FILE="/tmp/metrics.prom"

IS_LEADER="false"
LOOP_COUNT=0

echo "[healer] Starting redis-healer for ${HOSTNAME} (ordinal=${ORDINAL}, replicas=${REPLICAS}, primaries=${PRIMARIES})"

# ---------------------------------------------------------------------------
# Auxiliares
# ---------------------------------------------------------------------------

node_fqdn() { echo "${SERVICENAME}-${1}.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local"; }

redis_local() { redis-cli -h localhost -p 6379 "$@" 2>/dev/null; }

now_ts() { date -u +%s 2>/dev/null || echo 0; }

elapsed_since() {
  # elapsed_since <arquivo> <padrao_se_ausente>
  _file="${1}"; _default="${2:-9999}"
  [ -f "${_file}" ] || { echo "${_default}"; return; }
  _then=$(cat "${_file}" 2>/dev/null || echo 0)
  _now=$(now_ts)
  echo $(( _now - _then ))
}

touch_file() { echo "$(now_ts)" > "${1}" 2>/dev/null || true; }

kubectl_safe() {
  # Executa kubectl; suprime erros para o sidecar nunca cair em falhas da API K8s
  "${KUBECTL_BIN}" "$@" 2>/dev/null || true
}

emit_k8s_event() {
  # emit_k8s_event <motivo> <mensagem> [warning|normal]
  _reason="${1}"; _msg="${2}"; _type="${3:-Warning}"
  kubectl_safe create event "${HOSTNAME}-$(now_ts)" \
    --namespace="${NAMESPACE}" \
    --field-selector="" \
    --type="${_type}" \
    --reason="${_reason}" \
    --message="${_msg}" \
    --for="pod/${HOSTNAME}" >/dev/null 2>&1 || true
  echo "[healer] EVENT ${_type}/${_reason}: ${_msg}"
}

# ---------------------------------------------------------------------------
# Gerenciamento do Lease — adquire ou renova a cada RENEW_INTERVAL segundos
# ---------------------------------------------------------------------------
manage_lease() {
  # Apenas nos saudaveis competem pela lideranca
  if [ "${CLUSTER_STATE}" != "ok" ]; then
    IS_LEADER="false"
    return
  fi

  _now=$(now_ts)
  # Lease API espera timestamp com fração de segundos (RFC3339 microseconds)
  _ts="$(date -u +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")".000000Z

  # Le os campos atuais do Lease (jsonpath evita parser fragil com regex)
  _holder=$("${KUBECTL_BIN}" get lease "${LEASE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || echo "")
  _renew=$("${KUBECTL_BIN}" get lease "${LEASE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.renewTime}' 2>/dev/null || echo "")

  # Cria o Lease se ele nao existir
  if [ -z "${_holder}" ] && [ -z "${_renew}" ]; then
    # Usa ${KUBECTL_BIN} diretamente (não kubectl_safe) para detectar 409 Conflict race
    if "${KUBECTL_BIN}" create -f - <<EOF >/dev/null 2>&1
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: ${LEASE_NAME}
  namespace: ${NAMESPACE}
spec:
  holderIdentity: ${HOSTNAME}
  leaseDurationSeconds: ${LEASE_DURATION}
  acquireTime: "${_ts}"
  renewTime: "${_ts}"
  leaseTransitions: 0
EOF
    then
      IS_LEADER="true"
      echo "[healer] Created Lease and acquired leadership."
    else
      IS_LEADER="false"
      echo "[healer] Lease creation lost to race with another pod."
    fi
    return
  fi

  # Calcula a idade do Lease
  if [ -n "${_renew}" ]; then
    # BusyBox date: usa -D para o formato de entrada (RFC3339 sem nanossegundos)
    _renew_clean=$(echo "${_renew}" | sed -E 's/\.[0-9]+Z$/Z/')
    _renew_s=$(date -D '%Y-%m-%dT%H:%M:%SZ' -d "${_renew_clean}" +%s 2>/dev/null || echo "0")
    [ "${_renew_s}" -eq 0 ] && _renew_s=${_now}  # fallback: trata como atual (nao expira)
    _age=$(( _now - _renew_s ))
  else
    _age=$(( LEASE_DURATION + 1 ))  # trata como expirado
  fi

  if [ "${_holder}" = "${HOSTNAME}" ]; then
    # Este pod detem o lease — renova
    kubectl_safe patch lease "${LEASE_NAME}" -n "${NAMESPACE}" \
      --type=merge \
      -p "{\"spec\":{\"renewTime\":\"${_ts}\"}}" >/dev/null && IS_LEADER="true" || IS_LEADER="false"
  elif [ "${_age}" -gt "${LEASE_DURATION}" ]; then
    # Lease expirado — tenta adquirir
    kubectl_safe patch lease "${LEASE_NAME}" -n "${NAMESPACE}" \
      --type=merge \
      -p "{\"spec\":{\"holderIdentity\":\"${HOSTNAME}\",\"acquireTime\":\"${_ts}\",\"renewTime\":\"${_ts}\"}}" \
      >/dev/null && IS_LEADER="true" || IS_LEADER="false"
    [ "${IS_LEADER}" = "true" ] && echo "[healer] Acquired expired lease."
  else
    IS_LEADER="false"
  fi
}

# ---------------------------------------------------------------------------
# Coleta de saude local — a cada 15 s, todos os sidecars
# ---------------------------------------------------------------------------
collect_local_health() {
  REDIS_ALIVE="false"
  CLUSTER_STATE="unknown"
  SELF_ROLE="unknown"
  SELF_HAS_SLOTS=0
  KNOWN_NODES=0
  STALE_NODES=0
  REPL_LINK="unknown"

  redis_local ping >/dev/null && REDIS_ALIVE="true" || return

  CLUSTER_INFO=$(redis_local cluster info)
  CLUSTER_STATE=$(echo "${CLUSTER_INFO}" | awk -F: '/^cluster_state:/{gsub(/\r/,"",$2); print $2}')
  KNOWN_NODES=$(echo "${CLUSTER_INFO}" | awk -F: '/^cluster_known_nodes:/{gsub(/\r/,"",$2); print $2}')

  CLUSTER_NODES_OUT=$(redis_local cluster nodes)
  MYSELF_LINE=$(echo "${CLUSTER_NODES_OUT}" | grep ' myself')
  SELF_ROLE=$(echo "${MYSELF_LINE}" | awk '{print $3}' | sed 's/,/ /g' | awk '{print $1}')
  STALE_NODES=$(echo "${CLUSTER_NODES_OUT}" | grep -cE '(fail|noaddr)' 2>/dev/null) || STALE_NODES=0

  # master: verifica contagem de slots; replica: verifica link de replicacao
  case "${SELF_ROLE}" in
    master)
      _slots=$(echo "${MYSELF_LINE}" | awk '{print $9}')
      [ -n "${_slots}" ] && [ "${_slots}" != "-" ] && SELF_HAS_SLOTS=1 || SELF_HAS_SLOTS=0
      ;;
    slave)
      REPL_INFO=$(redis_local info replication)
      REPL_LINK=$(echo "${REPL_INFO}" | awk -F: '/^master_link_status:/{gsub(/\r/,"",$2); print $2}')
      SELF_HAS_SLOTS=0  # replicas nao possuem slots
      if [ "${REPL_LINK}" = "down" ]; then
        [ -f "${REPL_LINK_DOWN_SINCE}" ] || touch_file "${REPL_LINK_DOWN_SINCE}"
      else
        rm -f "${REPL_LINK_DOWN_SINCE}" 2>/dev/null || true
      fi
      ;;
  esac

  # Alerta: master sem slots (problema estrutural, apenas alerta)
  if [ "${SELF_ROLE}" = "master" ] && [ "${SELF_HAS_SLOTS}" -eq 0 ]; then
    emit_k8s_event "REDIS_MASTER_NO_SLOTS" \
      "Pod ${HOSTNAME}: master role but no slot ranges assigned — structural inversion detected" "Warning"
  fi

  # Alerta: cluster_state=fail
  if [ "${CLUSTER_STATE}" = "fail" ]; then
    emit_k8s_event "REDIS_CLUSTER_FAIL" \
      "Pod ${HOSTNAME}: cluster_state=fail" "Warning"
  fi
}

# ---------------------------------------------------------------------------
# Exporta metricas no formato Prometheus para arquivo e stdout
# ---------------------------------------------------------------------------
export_metrics() {
  _alive=0; [ "${REDIS_ALIVE}" = "true" ] && _alive=1
  _cs=0; [ "${CLUSTER_STATE}" = "ok" ] && _cs=1
  _lead=0; [ "${IS_LEADER}" = "true" ] && _lead=1
  _repl=0; [ "${REPL_LINK}" = "up" ] && _repl=1

  cat > "${METRICS_FILE}" <<METRICS
# HELP redis_healer_redis_alive 1=processo redis respondendo a ping
redis_healer_redis_alive{pod="${HOSTNAME}"} ${_alive}
# HELP redis_healer_cluster_state 1=ok 0=fail ou desconhecido
redis_healer_cluster_state{pod="${HOSTNAME}"} ${_cs}
# HELP redis_healer_is_leader 1=este sidecar detem o Lease de healing
redis_healer_is_leader{pod="${HOSTNAME}"} ${_lead}
# HELP redis_healer_known_nodes Total de nos conhecidos no cluster
redis_healer_known_nodes{pod="${HOSTNAME}"} ${KNOWN_NODES}
# HELP redis_healer_stale_nodes Nos em estado fail|noaddr
redis_healer_stale_nodes{pod="${HOSTNAME}"} ${STALE_NODES}
# HELP redis_healer_self_has_slots 1=este master possui >=1 faixa de slots
redis_healer_self_has_slots{pod="${HOSTNAME}"} ${SELF_HAS_SLOTS}
# HELP redis_healer_repl_link_up 1=link da replica esta ativo
redis_healer_repl_link_up{pod="${HOSTNAME}"} ${_repl}
# HELP redis_healer_loop_count Total de iteracoes do loop do healer
redis_healer_loop_count{pod="${HOSTNAME}"} ${LOOP_COUNT}
METRICS
  echo "[healer] metrics: state=${CLUSTER_STATE} role=${SELF_ROLE} leader=${IS_LEADER} stale=${STALE_NODES} nodes=${KNOWN_NODES}"
}

# ---------------------------------------------------------------------------
# check_multi_pod_failure — verdadeiro se >1 pod emitiu evento REDIS_CLUSTER_FAIL
# (suprime acoes de Tier 2 durante falhas em multiplos pods)
# ---------------------------------------------------------------------------
check_multi_pod_failure() {
  IS_MULTI_FAILURE="false"
  _count=$("${KUBECTL_BIN}" get events -n "${NAMESPACE}" \
    --field-selector "reason=REDIS_CLUSTER_FAIL" \
    -o jsonpath='{range .items[*]}{.involvedObject.name}{"\n"}{end}' 2>/dev/null \
    | sort -u | wc -l | tr -d '[:space:]' || echo 0)
  [ "${_count:-0}" -gt 1 ] && IS_MULTI_FAILURE="true"
}

# ---------------------------------------------------------------------------
# TIER 2: heal_stale_nodes
# Executa forget em nos em fail|noaddr por > 5 min, em todos os peers alcancaveis
# Circuit breaker: maximo de 1 acao de forget por janela de 10 min
# ---------------------------------------------------------------------------
heal_stale_nodes() {
  # Verifica circuit breaker
  _elapsed=$(elapsed_since "${LAST_FORGET_TIME}" 9999)
  [ "${_elapsed}" -lt 600 ] && return

  _stale_ids=$(redis_local cluster nodes | grep -E '(fail|noaddr)' | awk '{print $1}')
  [ -z "${_stale_ids}" ] && { rm -f "${STALE_FIRST_SEEN}" 2>/dev/null; return; }

  # Registra primeiro instante observado
  [ -f "${STALE_FIRST_SEEN}" ] || touch_file "${STALE_FIRST_SEEN}"
  _stale_age=$(elapsed_since "${STALE_FIRST_SEEN}" 0)

  # So atua apos limiar de 5 minutos
  [ "${_stale_age}" -lt 300 ] && return

  echo "[healer] TIER2: forgetting stale nodes (age=${_stale_age}s): ${_stale_ids}"
  _i=0
  while [ "${_i}" -lt "${REPLICAS}" ]; do
    _fqdn=$(node_fqdn "${_i}")
    if redis-cli -h "${_fqdn}" -p 6379 ping >/dev/null 2>&1; then
      for _id in ${_stale_ids}; do
        redis-cli -h "${_fqdn}" -p 6379 cluster forget "${_id}" >/dev/null 2>&1 || true
      done
    fi
    _i=$(( _i + 1 ))
  done

  touch_file "${LAST_FORGET_TIME}"
  rm -f "${STALE_FIRST_SEEN}" 2>/dev/null || true
  emit_k8s_event "REDIS_HEALER_FORGET" \
    "Pod ${HOSTNAME}: forgot stale nodes (${_stale_ids})" "Normal"
}

# ---------------------------------------------------------------------------
# TIER 2: heal_replication
# Cura replica que teve master_link_status=down por > 2 minutos.
# Circuit breaker: maximo de 1 replicate por janela de 10 min
# ---------------------------------------------------------------------------
heal_replication() {
  [ "${SELF_ROLE}" = "slave" ] || return
  [ "${REPL_LINK}" = "up" ] && return

  # Verifica circuit breaker
  _elapsed=$(elapsed_since "${LAST_REPLICATE_TIME}" 9999)
  [ "${_elapsed}" -lt 600 ] && return

  # So atua apos limiar de 2 minutos
  _link_age=$(elapsed_since "${REPL_LINK_DOWN_SINCE}" 0)
  [ "${_link_age}" -lt 120 ] && return

  _mord=$(( ORDINAL % PRIMARIES ))
  _mfqdn=$(node_fqdn "${_mord}")

  # Verifica se o master esperado esta alcancavel antes de agir
  redis-cli -h "${_mfqdn}" -p 6379 ping >/dev/null 2>&1 || return

  _mid=$(redis-cli -h "${_mfqdn}" -p 6379 cluster myid 2>/dev/null | tr -d '[:space:]')
  [ -z "${_mid}" ] && return

  echo "[healer] TIER2: replica link down ${_link_age}s — replicating to ${_mfqdn} (${_mid})"
  redis_local cluster replicate "${_mid}" >/dev/null || true
  touch_file "${LAST_REPLICATE_TIME}"
  emit_k8s_event "REDIS_HEALER_REPLICATE" \
    "Pod ${HOSTNAME}: re-established replication to ${_mfqdn}" "Normal"
}

# ---------------------------------------------------------------------------
# TIER 2: heal_mesh
# Reintroduz peer conhecido que esta ausente no cluster nodes local
# Circuit breaker: maximo de 1 meet por peer por janela de 5 min
# ---------------------------------------------------------------------------
heal_mesh() {
  _i=0
  while [ "${_i}" -lt "${REPLICAS}" ]; do
    [ "${_i}" = "${ORDINAL}" ] && { _i=$(( _i + 1 )); continue; }
    _fqdn=$(node_fqdn "${_i}")
    _meet_file="${LAST_MEET_TIME}_${_i}"
    _elapsed=$(elapsed_since "${_meet_file}" 9999)

    # So atua se o peer estiver alcancavel e ausente no cluster nodes local
    if redis-cli -h "${_fqdn}" -p 6379 ping >/dev/null 2>&1; then
      _in_topo=$(redis_local cluster nodes | grep "${_fqdn}" | wc -l | tr -d '[:space:]')
      if [ "${_in_topo:-0}" -eq 0 ] && [ "${_elapsed}" -ge 300 ]; then
        echo "[healer] TIER2: peer ${_fqdn} missing from topology — sending CLUSTER MEET"
        redis_local cluster meet "${_fqdn}" 6379 >/dev/null || true
        touch_file "${_meet_file}"
        emit_k8s_event "REDIS_HEALER_MEET" \
          "Pod ${HOSTNAME}: re-introduced ${_fqdn} via CLUSTER MEET" "Normal"
      fi
    fi
    _i=$(( _i + 1 ))
  done
}

# ---------------------------------------------------------------------------
# Checagens cluster-wide somente no lider (a cada 4 loops = ~60s)
# Somente alerta — sem remediacao automatica para estes casos
# ---------------------------------------------------------------------------
run_cluster_wide_check() {
  echo "[healer] leader: running cluster-wide check..."

  _check_out=$(redis-cli --cluster check "localhost:6379" 2>/dev/null || true)

  # Open slots (migrating/importing — NAO confundir com linhas normais "-> N keys")
  OPEN_SLOTS=$(echo "${_check_out}" | grep -c 'migrating\|importing' 2>/dev/null) || OPEN_SLOTS=0
  if [ "${OPEN_SLOTS:-0}" -gt 0 ]; then
    emit_k8s_event "REDIS_OPEN_SLOTS" \
      "Pod ${HOSTNAME}: ${OPEN_SLOTS} open slot(s) detected — manual intervention required" "Warning"
  fi

  # Contagem de masters
  ACTUAL_MASTERS=$(redis_local cluster nodes | grep -c ' master' 2>/dev/null) || ACTUAL_MASTERS=0
  if [ "${ACTUAL_MASTERS}" != "${PRIMARIES}" ]; then
    emit_k8s_event "REDIS_MASTER_COUNT_MISMATCH" \
      "Pod ${HOSTNAME}: expected ${PRIMARIES} masters but found ${ACTUAL_MASTERS}" "Warning"
  fi

  # Cobertura completa de slots
  _assigned=$(redis_local cluster info | awk -F: '/^cluster_slots_assigned:/{gsub(/\r/,"",$2); print $2}')
  if [ "${_assigned}" != "16384" ]; then
    emit_k8s_event "REDIS_INCOMPLETE_SLOTS" \
      "Pod ${HOSTNAME}: only ${_assigned}/16384 slots assigned" "Warning"
  fi

  echo "[healer] cluster-wide check complete: masters=${ACTUAL_MASTERS}/${PRIMARIES} slots=${_assigned}/16384 open=${OPEN_SLOTS}"
}

# =============================================================================
# LOOP PRINCIPAL
# =============================================================================

while true; do
  # 1. Saude local (a cada 15 s)
  collect_local_health || true

  # 2. Eleicao de lider
  manage_lease || true

  # 3. Exportacao de metricas
  export_metrics || true

  # 4. Healing Tier-2 (lider, saudavel, sem falha multi-pod)
  if [ "${IS_LEADER}" = "true" ] && [ "${CLUSTER_STATE}" = "ok" ]; then
    check_multi_pod_failure || true
    if [ "${IS_MULTI_FAILURE}" != "true" ]; then
      heal_stale_nodes   || true
      heal_replication   || true
      heal_mesh          || true
    else
      echo "[healer] Multi-pod failure detected — suppressing Tier-2 actions"
    fi
  fi

  # 5. Checagem cluster-wide (lider, a cada ~60 s)
  if [ "${IS_LEADER}" = "true" ] && [ $(( LOOP_COUNT % 4 )) -eq 0 ]; then
    run_cluster_wide_check || true
  fi

  LOOP_COUNT=$(( LOOP_COUNT + 1 ))
  sleep 15
done
