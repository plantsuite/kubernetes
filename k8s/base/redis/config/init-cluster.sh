#!/bin/sh

# Use a variável de ambiente REPLICAS diretamente
echo "Initializing cluster for ${REPLICAS} replicas"

if [ "${REPLICAS}" -eq "1" ]; then
  echo "Single node deployment. Skipping cluster initialization"
  exit 0
fi

SERVICENAME=$(echo ${HOSTNAME} | rev | cut -d'-' -f2- | rev)
ORDINAL=$(echo ${HOSTNAME} | rev | cut -d'-' -f1 | rev)
if [ -z "${NAMESPACE}" ]; then
  NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "redis")
fi
POD_DNS="${HOSTNAME}.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local"
PRIMARIES=$(((${REPLICAS} + 1) / 2))

echo "Initializing as ordinal $ORDINAL and $PRIMARIES primaries (pod dns: ${POD_DNS})"

# Verifique o estado do cluster primeiro
CLUSTER_STATE=$(redis-cli -h localhost -p 6379 cluster info 2>/dev/null | grep 'cluster_state' | awk '{print $2}')

# Verifique o estado do nó para REPLICAS > 1
if [ "$CLUSTER_STATE" = "ok" ] && redis-cli -h localhost -p 6379 cluster nodes 2>/dev/null | grep -q "${POD_DNS}"; then
  echo "Node ${POD_DNS} already in healthy cluster (likely restart with volume data). Checking replication..."
  # Para réplicas, confirme a replicação correta
  if [ "${ORDINAL}" -ge "${PRIMARIES}" ]; then
    PRIMARY_ORDINAL=$((ORDINAL % PRIMARIES))
    PRIMARY_HOST="${SERVICENAME}-${PRIMARY_ORDINAL}.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local"
    if ! redis-cli -h localhost -p 6379 info replication 2>/dev/null | grep -q "master_host:${PRIMARY_HOST}"; then
      echo "Replica not correctly set, reconfiguring..."
      redis-cli -h localhost -p 6379 cluster replicate $(redis-cli -h ${PRIMARY_HOST} -p 6379 cluster myid 2>/dev/null)
    fi
  fi
  echo "Node is healthy, exiting"
  exit 0
else
  echo "Node not in cluster or cluster not healthy, checking for stray data..."
  # Se tiver dados (ex.: gravações prematuras), limpe para join limpo
  if redis-cli -h localhost -p 6379 dbsize 2>/dev/null | grep -q "^[1-9]"; then
    echo "Flushing stray data for clean join"
    redis-cli -h localhost -p 6379 flushdb
  fi
fi

if [ "${ORDINAL}" = "0" ]; then
  echo "This is the primary node"

  until redis-cli -h localhost -p 6379 ping >/dev/null 2>&1; do
    echo "Waiting for local Redis to start..."
    sleep 10
  done
  echo "Local Redis is ready"

  if ! redis-cli -h localhost -p 6379 cluster info 2>/dev/null | grep -q 'cluster_state:ok'; then
    echo "Initializing cluster..."

    NODES=""
    for i in $(seq 0 $((${REPLICAS}-1))); do
      NODE="${SERVICENAME}-${i}.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local"

      until redis-cli -h ${NODE} -p 6379 ping >/dev/null 2>&1; do
        echo "Waiting for ${NODE} to be ready..."
        sleep 10
      done

      echo "${NODE} is ready, adding to cluster nodes list..."
      NODES="${NODES} ${NODE}:6379"
    done

    REPLICA_COUNT=$(((${REPLICAS} - ${PRIMARIES}) / ${PRIMARIES}))

    echo "Creating cluster with ${PRIMARIES} primaries and ${REPLICA_COUNT} replicas per primary"
    echo "Creating cluster with nodes: ${NODES}"
    echo "yes" | redis-cli --cluster create ${NODES} --cluster-replicas ${REPLICA_COUNT}

    echo "Cluster initialized"
  else
    echo "Cluster already initialized"
  fi
elif [ "${ORDINAL}" -ge "${PRIMARIES}" ]; then
  PRIMARY_INDEX=$((${ORDINAL} % ${PRIMARIES}))
  PRIMARY_HOST="${SERVICENAME}-${PRIMARY_INDEX}.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local"

  echo "This is a replica node. Will join cluster via ${PRIMARY_HOST}"
  until redis-cli -h ${PRIMARY_HOST} -p 6379 ping >/dev/null 2>&1; do
    echo "Waiting for primary ${PRIMARY_HOST} to be ready..."
    sleep 10
  done

  echo "Primary ${PRIMARY_HOST} is ready, joining cluster..."
  redis-cli --cluster add-node ${POD_DNS}:6379 ${PRIMARY_HOST}:6379 --cluster-slave
else
  echo "This is a primary node. Will join cluster via ${SERVICENAME}-0"
  until redis-cli -h ${SERVICENAME}-0.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local -p 6379 ping 2>/dev/null; do
    echo "Waiting for ${SERVICENAME}-0 to be ready..."
    sleep 10
  done

  echo "Cluster primary is ready, joining cluster..."
  redis-cli --cluster add-node ${POD_DNS}:6379 ${SERVICENAME}-0.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local:6379
fi
