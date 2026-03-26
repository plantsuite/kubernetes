#!/bin/sh
# =============================================================================
# init-cluster.sh — Inicializa, une e valida o Redis Cluster
# =============================================================================
# Executa em PRIMEIRO PLANO dentro de um pod na StatefulSet Redis.
# redis-server executa em background. Script sai com código 0 quando pronto.
# Saída não-zero → entrypoint mata redis-server → pod reinicia.
#
# Responsabilidades:
#   • Verifica se este pod é membro do cluster (via nodes.conf ou gossip)
#   • Aguarda bootstrap do pod-0 antes de não-0 tentarem se juntar
#   • Cria cluster com todos 6 pods atomicamente (path-0 ordinal=0)
#   • Junta como replica com master correto via cluster-master-id
#   • Limpa nós stale e verifica atribuição de papel (master/replica)
# =============================================================================

set -e

# ---------------------------------------------------------------------------
# Derived variables
# ---------------------------------------------------------------------------
SERVICENAME=$(echo "${HOSTNAME}" | rev | cut -d'-' -f2- | rev)
ORDINAL=$(echo "${HOSTNAME}" | rev | cut -d'-' -f1 | rev)
if [ -z "${NAMESPACE}" ]; then
  NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "redis")
fi

if [ "${REPLICAS}" -le 1 ]; then
  echo "[init-cluster] Single-node deployment — skipping cluster init."
  exit 0
fi

PRIMARIES=$(( (REPLICAS + 1) / 2 ))
REPLICA_COUNT=$(( (REPLICAS - PRIMARIES) / PRIMARIES ))
POD_FQDN="${HOSTNAME}.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local"

echo "[init-cluster] HOSTNAME=${HOSTNAME} ORDINAL=${ORDINAL} NAMESPACE=${NAMESPACE}"
echo "[init-cluster] REPLICAS=${REPLICAS} PRIMARIES=${PRIMARIES} REPLICA_COUNT=${REPLICA_COUNT}"
echo "[init-cluster] POD_FQDN=${POD_FQDN}"

# ---------------------------------------------------------------------------
# node_fqdn <ordinal> — retorna FQDN de um pod ordinal
# ---------------------------------------------------------------------------
node_fqdn() {
  echo "${SERVICENAME}-${1}.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local"
}

# ---------------------------------------------------------------------------
# wait_for_local_redis — aguarda ping do redis local (max 180s)
# ---------------------------------------------------------------------------
wait_for_local_redis() {
  echo "[init-cluster] Waiting for local Redis (up to 180 s)..."
  _i=0
  while [ "${_i}" -lt 90 ]; do
    if redis-cli -h localhost -p 6379 ping >/dev/null 2>&1; then
      echo "[init-cluster] Local Redis ready."
      return 0
    fi
    _i=$(( _i + 1 ))
    sleep 2
  done
  echo "[init-cluster] ERROR: Local Redis not ready after 180 s."
  return 1
}

# ---------------------------------------------------------------------------
# get_cluster_state — prints "ok", "fail", or "" on error
# ---------------------------------------------------------------------------
get_cluster_state() {
  redis-cli -h localhost -p 6379 cluster info 2>/dev/null \
    | awk -F: '/^cluster_state:/{gsub(/\r/, "", $2); print $2}'
}

# ---------------------------------------------------------------------------
# wait_for_initial_cluster_state — short wait for first observable state.
# Returns "ok", "fail", or "" (empty) if still not observable.
# ---------------------------------------------------------------------------
wait_for_initial_cluster_state() {
  _st=$(get_cluster_state)
  case "${_st}" in
    ok|fail)
      echo "${_st}"
      return 0
      ;;
  esac

  echo "[init-cluster] Initial cluster_state not observable yet — waiting up to 10 s..." 1>&2
  _i=0
  while [ "${_i}" -lt 10 ]; do
    sleep 1
    _st=$(get_cluster_state)
    case "${_st}" in
      ok|fail)
        echo "${_st}"
        return 0
        ;;
    esac
    _i=$(( _i + 1 ))
  done

  echo ""
  return 0
}

# ---------------------------------------------------------------------------
# wait_for_cluster_ok — 30 × 5 s = 150 s max (gossip recovery after transient fail)
# ---------------------------------------------------------------------------
wait_for_cluster_ok() {
  echo "[init-cluster] Waiting for cluster_state=ok (gossip recovery, up to 150 s)..."
  _i=0
  while [ "${_i}" -lt 30 ]; do
    _st=$(get_cluster_state)
    if [ "${_st}" = "ok" ]; then
      echo "[init-cluster] cluster_state=ok achieved after $(( _i * 5 )) s."
      return 0
    fi
    echo "[init-cluster] cluster_state=${_st} — attempt $(( _i + 1 ))/30, sleeping 5 s..."
    _i=$(( _i + 1 ))
    sleep 5
  done
  echo "[init-cluster] WARN: cluster_state did not recover within 150 s."
  return 1
}

# ---------------------------------------------------------------------------
# has_known_peers_on_disk — true when /data/nodes.conf contains peer entries.
# Excludes the local "myself" entry, the "vars" metadata line, and empty/comment
# lines. Returns true only when at least one actual peer entry is present.
# Detecta estado do cluster via cluster info. Valores possíveis: ok, fail, unknown.
# ---------------------------------------------------------------------------
has_known_peers_on_disk() {
  _nconf="/data/nodes.conf"
  [ -f "${_nconf}" ] || return 1
  _cnt=$(grep -v '^[[:space:]]*$' "${_nconf}" 2>/dev/null \
    | grep -v '^[[:space:]]*#' \
    | grep -v 'myself' \
    | grep -v '^vars ' \
    | wc -l | tr -d '[:space:]')
  [ "${_cnt:-0}" -gt 0 ]
}

# ---------------------------------------------------------------------------
# am_i_member — true if local cluster nodes output contains the "myself" flag.
# Verifica se este pod é membro da topologia (usa output gossip com FQDN, não IP).
# cluster-preferred-endpoint-type=hostname is set.
# ---------------------------------------------------------------------------
am_i_member() {
  redis-cli -h localhost -p 6379 cluster nodes 2>/dev/null | grep -q 'myself'
}

# ---------------------------------------------------------------------------
# count_reachable_masters — echo count of ordinals 0..(PRIMARIES-1) that ping.
# Counts reachable pod endpoints, not verified master roles, to avoid
# Valida que todas as 6 réplicas existem antes de nenhum pod prosseguir.
# ---------------------------------------------------------------------------
count_reachable_masters() {
  _cnt=0
  _i=0
  while [ "${_i}" -lt "${PRIMARIES}" ]; do
    _fqdn=$(node_fqdn "${_i}")
    if redis-cli -h "${_fqdn}" -p 6379 ping >/dev/null 2>&1; then
      _cnt=$(( _cnt + 1 ))
    fi
    _i=$(( _i + 1 ))
  done
  echo "${_cnt}"
}

# ---------------------------------------------------------------------------
# wait_for_bootstrap_node — polls ordinal-0 cluster_state=ok, 90 × 10 s = 900 s.
# Não-0 pods devem aguardar pod-0 completar cluster create antes de agir.
# ---------------------------------------------------------------------------
wait_for_bootstrap_node() {
  _boot=$(node_fqdn 0)
  echo "[init-cluster] Waiting for bootstrap node ${_boot} (up to 900 s)..."
  _i=0
  while [ "${_i}" -lt 90 ]; do
    _st=$(redis-cli -h "${_boot}" -p 6379 cluster info 2>/dev/null \
      | awk -F: '/^cluster_state:/{gsub(/\r/, "", $2); print $2}')
    if [ "${_st}" = "ok" ]; then
      echo "[init-cluster] Bootstrap node reached cluster_state=ok."
      return 0
    fi
    echo "[init-cluster] Bootstrap state=${_st} — attempt $(( _i + 1 ))/90, sleeping 10 s..."
    _i=$(( _i + 1 ))
    sleep 10
  done
  echo "[init-cluster] ERROR: Bootstrap node did not reach cluster_state=ok within 900 s."
  return 1
}

# ---------------------------------------------------------------------------
# any_node_has_existing_cluster — true if any of the REPLICAS nodes reports
# more than 1 line from CLUSTER NODES (i.e., knows about at least one peer).
# Used as a guard in bootstrap_cluster to prevent double-bootstrap.
# ---------------------------------------------------------------------------
any_node_has_existing_cluster() {
  _i=0
  while [ "${_i}" -lt "${REPLICAS}" ]; do
    _fqdn=$(node_fqdn "${_i}")
    if redis-cli -h "${_fqdn}" -p 6379 ping >/dev/null 2>&1; then
      _lc=$(redis-cli -h "${_fqdn}" -p 6379 cluster nodes 2>/dev/null \
        | grep -v '^[[:space:]]*$' | wc -l | tr -d '[:space:]')
      if [ "${_lc:-0}" -gt 1 ]; then
        echo "[init-cluster] Node ${_fqdn} already has ${_lc} cluster node entries."
        return 0
      fi
    fi
    _i=$(( _i + 1 ))
  done
  return 1
}

# ---------------------------------------------------------------------------
# cleanup_stale_nodes — CLUSTER FORGET fail|noaddr nodes on ALL reachable peers.
# Runs on every reachable peer to prevent gossip re-propagation of stale entries.
# ---------------------------------------------------------------------------
cleanup_stale_nodes() {
  echo "[init-cluster] cleanup_stale_nodes: scanning for fail/noaddr entries..."
  _stale=$(redis-cli -h localhost -p 6379 cluster nodes 2>/dev/null \
    | grep -E '(fail|noaddr)' | awk '{print $1}' || true)
  if [ -z "${_stale}" ]; then
    echo "[init-cluster] No stale nodes found."
    return 0
  fi
  echo "[init-cluster] Stale node IDs: ${_stale}"
  _i=0
  while [ "${_i}" -lt "${REPLICAS}" ]; do
    _fqdn=$(node_fqdn "${_i}")
    if redis-cli -h "${_fqdn}" -p 6379 ping >/dev/null 2>&1; then
      for _id in ${_stale}; do
        redis-cli -h "${_fqdn}" -p 6379 cluster forget "${_id}" >/dev/null 2>&1 || true
      done
    fi
    _i=$(( _i + 1 ))
  done
  echo "[init-cluster] Stale node cleanup complete."
}

# ---------------------------------------------------------------------------
# verify_slot_coverage — checks cluster_slots_assigned=16384.
  # Ordinal-0 executa cluster fix se cobertura de slots está incompleta.
# ---------------------------------------------------------------------------
verify_slot_coverage() {
  _slots=$(redis-cli -h localhost -p 6379 cluster info 2>/dev/null \
    | awk -F: '/^cluster_slots_assigned:/{gsub(/\r/, "", $2); print $2}')
  echo "[init-cluster] cluster_slots_assigned=${_slots}"
  if [ "${_slots}" != "16384" ]; then
    if [ "${ORDINAL}" = "0" ]; then
      echo "[init-cluster] AVISO: Cobertura de slots incompleta (${_slots}/16384) — executando rebalance..."
      redis-cli --cluster fix "localhost:6379" >/dev/null 2>&1 || true
    else
      echo "[init-cluster] AVISO: Cobertura de slots incompleta (${_slots}/16384) — pod-0 executa rebalance."
    fi
  else
    echo "[init-cluster] Slot coverage 16384/16384 — OK."
  fi
}

# ---------------------------------------------------------------------------
# verify_replica_assignment — for replica pods, confirm attached to expected master.
# Field 4 of CLUSTER NODES for the "myself" line is the replication-source node ID
# ("-" for masters, master-node-id for replicas).
# ---------------------------------------------------------------------------
verify_replica_assignment() {
  [ "${ORDINAL}" -ge "${PRIMARIES}" ] || return 0  # not a replica — nothing to do
  _mord=$(( ORDINAL % PRIMARIES ))
  _mfqdn=$(node_fqdn "${_mord}")
  _expected_id=$(redis-cli -h "${_mfqdn}" -p 6379 cluster myid 2>/dev/null | tr -d '[:space:]')
  if [ -z "${_expected_id}" ]; then
    echo "[init-cluster] WARN: Cannot get node ID from ${_mfqdn} — skipping verify_replica_assignment."
    return 0
  fi
  _actual_id=$(redis-cli -h localhost -p 6379 cluster nodes 2>/dev/null \
    | grep ' myself' | awk '{print $4}')
  echo "[init-cluster] verify_replica_assignment: expected=${_expected_id} actual=${_actual_id}"
  if [ "${_actual_id}" != "${_expected_id}" ]; then
    echo "[init-cluster] Replica mis-assigned — replicating to ${_mfqdn} (${_expected_id})..."
    redis-cli -h localhost -p 6379 cluster replicate "${_expected_id}" || true
    sleep 3
  else
    echo "[init-cluster] Replica assignment correct."
  fi
}

# ---------------------------------------------------------------------------
# verify_master_assignment — ordinal-0 only: ensure ordinals 0..PRIMARIES-1 are
# masters. Triggers CLUSTER FAILOVER TAKEOVER for any inverted assignment.
# Promove replica para master se necessário (via failover takeover, preservando slots).
# ---------------------------------------------------------------------------
verify_master_assignment() {
  echo "[init-cluster] verify_master_assignment: checking ordinals 0..$((PRIMARIES - 1))..."
  _i=0
  while [ "${_i}" -lt "${PRIMARIES}" ]; do
    _fqdn=$(node_fqdn "${_i}")
    _role=$(redis-cli -h "${_fqdn}" -p 6379 role 2>/dev/null | head -n 1 | tr -d '[:space:]')
    echo "[init-cluster] Ordinal ${_i} (${_fqdn}) role=${_role}"
    if [ "${_role}" = "slave" ]; then
      echo "[init-cluster] WARN: Ordinal ${_i} is slave — triggering CLUSTER FAILOVER TAKEOVER..."
      redis-cli -h "${_fqdn}" -p 6379 cluster failover takeover 2>/dev/null || true
      sleep 5
      _newrole=$(redis-cli -h "${_fqdn}" -p 6379 role 2>/dev/null | head -n 1 | tr -d '[:space:]')
      echo "[init-cluster] Post-failover: ordinal ${_i} role=${_newrole}"
    fi
    _i=$(( _i + 1 ))
  done
}

# ---------------------------------------------------------------------------
# join_as_replica — resolve master node ID, then call add-node --cluster-slave.
# Une como replica com o master correto (sempre passa --cluster-master-id).
# ---------------------------------------------------------------------------
join_as_replica() {
  _mord=$(( ORDINAL % PRIMARIES ))
  _mfqdn=$(node_fqdn "${_mord}")
  _boot=$(node_fqdn 0)
  echo "[init-cluster] join_as_replica: master=ordinal-${_mord} (${_mfqdn}), join via ${_boot}..."
  _mid=$(redis-cli -h "${_mfqdn}" -p 6379 cluster myid 2>/dev/null | tr -d '[:space:]')
  if [ -z "${_mid}" ]; then
    echo "[init-cluster] ERROR: Cannot get node ID from ${_mfqdn}."
    return 1
  fi
  echo "[init-cluster] Master node ID: ${_mid}"
  redis-cli --cluster add-node \
    "${POD_FQDN}:6379" \
    "${_boot}:6379" \
    --cluster-slave \
    --cluster-master-id "${_mid}"
  echo "[init-cluster] join_as_replica complete."
}

# ---------------------------------------------------------------------------
# join_as_primary — add this non-bootstrap primary into an existing cluster.
# Called only when the cluster already exists and this primary ordinal is absent.
# ---------------------------------------------------------------------------
join_as_primary() {
  _boot=$(node_fqdn 0)
  echo "[init-cluster] join_as_primary: joining via bootstrap node ${_boot}..."
  redis-cli --cluster add-node "${POD_FQDN}:6379" "${_boot}:6379"
  echo "[init-cluster] join_as_primary complete."
}

# ---------------------------------------------------------------------------
# bootstrap_cluster — full cluster create; called only from ordinal-0 on a
# fresh/wiped node with no peers in nodes.conf.
# Não usa CLUSTER RESET SOFT (nós não têm prévia atribuição de slots).
# Cluster create registra todos 6 nós atomicamente: pods não-0 só precisam aguardar.
# Nodes listed in order 0..5 so ordinals 0-2 are preferred as masters.
# ---------------------------------------------------------------------------
bootstrap_cluster() {
  echo "[init-cluster] === bootstrap_cluster ==="

  # Guard: abort if any node already belongs to an existing cluster
  if any_node_has_existing_cluster; then
    echo "[init-cluster] INFO: Existing cluster detected on at least one node — skipping create."
    return 0
  fi

  # Wait for all pods to become reachable before issuing cluster create
  echo "[init-cluster] Waiting for all ${REPLICAS} pods to be reachable..."
  _n=0
  while [ "${_n}" -lt "${REPLICAS}" ]; do
    _fqdn=$(node_fqdn "${_n}")
    _j=0
    until redis-cli -h "${_fqdn}" -p 6379 ping >/dev/null 2>&1; do
      echo "[init-cluster] Waiting for ${_fqdn}... (attempt $(( _j + 1 )))"
      _j=$(( _j + 1 ))
      if [ "${_j}" -ge 90 ]; then
        echo "[init-cluster] ERROR: ${_fqdn} not reachable after 180 s."
        return 1
      fi
      sleep 2
    done
    echo "[init-cluster] ${_fqdn} reachable."
    _n=$(( _n + 1 ))
  done

  # Build ordered node list 0..REPLICAS-1 so that ordinals 0-2 are assigned masters
  _nodes=""
  _n=0
  while [ "${_n}" -lt "${REPLICAS}" ]; do
    _nodes="${_nodes} $(node_fqdn ${_n}):6379"
    _n=$(( _n + 1 ))
  done

  echo "[init-cluster] Running cluster create: --cluster-replicas ${REPLICA_COUNT}"
  echo "[init-cluster] Nodes: ${_nodes}"
  # SC2086: intentional word-splitting — each element is a separate argument
  # shellcheck disable=SC2086
  echo "yes" | redis-cli --cluster create ${_nodes} --cluster-replicas "${REPLICA_COUNT}"

  echo "[init-cluster] Cluster created — sleeping 5 s for gossip convergence..."
  sleep 5

  # Corrige qualquer inversão master/slave via failover takeover.
  verify_master_assignment

  # Remove any stale entries left from the create sequence
  cleanup_stale_nodes

  # Confirm all 16384 slots are covered
  verify_slot_coverage

  echo "[init-cluster] bootstrap_cluster complete."
}

# ---------------------------------------------------------------------------
# _member_exit — common confirmed-member exit path (best-effort verify + clean)
# ---------------------------------------------------------------------------
_member_exit() {
  echo "[init-cluster] Node is a confirmed cluster member."
  verify_replica_assignment || true
  verify_slot_coverage      || true
  cleanup_stale_nodes       || true
  echo "[init-cluster] Validation complete — exiting 0."
  exit 0
}

# ---------------------------------------------------------------------------
# _join_and_exit — cluster is healthy but this node is not a member yet
# ---------------------------------------------------------------------------
_join_and_exit() {
  echo "[init-cluster] Cluster ok but node not yet a member — joining..."
  if [ "${ORDINAL}" -ge "${PRIMARIES}" ]; then
    join_as_replica
  else
    join_as_primary
  fi
  sleep 3
  verify_replica_assignment || true
  verify_slot_coverage      || true
  cleanup_stale_nodes       || true
  echo "[init-cluster] Join complete — exiting 0."
  exit 0
}

# =============================================================================
# MAIN STATE MACHINE
# =============================================================================

wait_for_local_redis
CLUSTER_STATE=$(wait_for_initial_cluster_state)
echo "[init-cluster] Initial cluster_state=${CLUSTER_STATE}"

case "${CLUSTER_STATE}" in

  # ---------------------------------------------------------------------------
  # PATH A: cluster_state = ok
  # ---------------------------------------------------------------------------
  ok)
    echo "[init-cluster] PATH A: cluster_state=ok"
    if am_i_member; then
      _member_exit
    else
      _join_and_exit
    fi
    ;;

  # ---------------------------------------------------------------------------
  # PATH B: cluster_state = fail
  # ---------------------------------------------------------------------------
  fail)
    echo "[init-cluster] PATH B: cluster_state=fail"

    if has_known_peers_on_disk; then
      # B.1 — nodes.conf tem entradas de peer → falha transitória (aguardar gossip).
      # Do NOT bootstrap. Do NOT call CLUSTER RESET SOFT.
      echo "[init-cluster] PATH B.1: nodes.conf has known peers — treating as transient failure."
      _reachable=$(count_reachable_masters)
      _quorum=$(( PRIMARIES / 2 + 1 ))
      echo "[init-cluster] Reachable master-ordinals=${_reachable}, quorum=${_quorum}"

      if [ "${_reachable}" -ge "${_quorum}" ]; then
        echo "[init-cluster] Quorum reachable — waiting for gossip to restore cluster_state=ok..."
        if wait_for_cluster_ok; then
          if am_i_member; then
            _member_exit
          else
            _join_and_exit
          fi
        else
          echo "[init-cluster] WARN: Gossip recovery timed out (150 s). Manual intervention may be needed."
          echo "[init-cluster] Exiting 0 to avoid unnecessary restart loop."
          exit 0
        fi
      else
        echo "[init-cluster] WARN: Quorum lost (reachable=${_reachable} < quorum=${_quorum})."
        echo "[init-cluster] Manual intervention required to restore cluster quorum. Exiting 0."
        exit 0
      fi

    else
      # B.2 — no peer entries on disk → fresh or wiped node (safe to bootstrap/join)
      echo "[init-cluster] PATH B.2: no peers in nodes.conf — fresh or wiped node."

      if [ "${ORDINAL}" = "0" ]; then
        echo "[init-cluster] Ordinal 0 — bootstrapping cluster..."
        bootstrap_cluster
        cleanup_stale_nodes  || true
        verify_slot_coverage || true
        echo "[init-cluster] Bootstrap complete — exiting 0."
        exit 0
      else
        # Aguarda pod-0 completar cluster create antes de não-0 prosseguir.
        # cluster create registers all 6 nodes atomically, so after pod-0 reports
        # cluster_state=ok this pod should already be a member.
        echo "[init-cluster] Ordinal ${ORDINAL} — waiting for ordinal-0 to bootstrap the cluster..."
        wait_for_bootstrap_node
        sleep 2  # brief settle after bootstrap node signals ok
        if am_i_member; then
          echo "[init-cluster] Was registered during cluster create by ordinal-0."
          _member_exit
        else
          echo "[init-cluster] Not yet a member after bootstrap — joining now..."
          _join_and_exit
        fi
      fi
    fi
    ;;

  # ---------------------------------------------------------------------------
  # PATH C: unexpected / empty cluster state
  # ---------------------------------------------------------------------------
  *)
    echo "[init-cluster] PATH C: unexpected cluster_state='${CLUSTER_STATE}'"
    echo "[init-cluster] No action taken — exiting 0 to avoid restart loop."
    exit 0
    ;;

esac
