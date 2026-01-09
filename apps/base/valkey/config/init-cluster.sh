#!/bin/sh

# Use the REPLICAS environment variable directly
echo "Initializing cluster for ${REPLICAS} replicas"

if [ "${REPLICAS}" -eq "1" ]; then
  echo "Single node deployment. Skipping cluster initialization"
  exit 0
fi

SERVICENAME=$(echo ${HOSTNAME} | rev | cut -d'-' -f2- | rev)
ORDINAL=$(echo ${HOSTNAME} | rev | cut -d'-' -f1 | rev)
PRIMARIES=$(((${REPLICAS} + 1) / 2))

echo "Initializing as ordinal $ORDINAL and $PRIMARIES primaries"
if [ "${ORDINAL}" = "0" ]; then
  echo "This is the primary node"

  until valkey-cli -h localhost -p 6379 ping >/dev/null 2>&1; do
    echo "Waiting for local Valkey to start..."
    sleep 2
  done
  echo "Local Valkey is ready"

  if ! valkey-cli -h localhost -p 6379 cluster info 2>/dev/null | grep -q 'cluster_state:ok'; then
    echo "Initializing cluster..."

    NODES=""
    for i in $(seq 0 $((${REPLICAS}-1))); do
      if [ "$i" = "0" ]; then
        NODE="${POD_IP}"
      else
        NODE="${SERVICENAME}-${i}.${SERVICENAME}.valkey.svc.cluster.local"
      fi

      until valkey-cli -h ${NODE} -p 6379 ping >/dev/null 2>&1; do
        echo "Waiting for ${NODE} to be ready..."
        sleep 5
      done

      NODES="${NODES} ${NODE}:6379"
    done

    REPLICA_COUNT=$(((${REPLICAS} - ${PRIMARIES}) / ${PRIMARIES}))

    echo "Creating cluster with ${PRIMARIES} primaries and ${REPLICA_COUNT} replicas per primary"
    echo "Creating cluster with nodes: ${NODES}"
    echo "yes" | valkey-cli --cluster create ${NODES} --cluster-replicas ${REPLICA_COUNT}

    echo "Cluster initialized"
  else
    echo "Cluster already initialized"
  fi
elif [ "${ORDINAL}" -ge "${PRIMARIES}" ]; then
  PRIMARY_INDEX=$((${ORDINAL} % ${PRIMARIES}))
  PRIMARY_HOST="${SERVICENAME}-${PRIMARY_INDEX}.${SERVICENAME}.valkey.svc.cluster.local"

  echo "This is a replica node. Will join cluster via ${PRIMARY_HOST}"
  until valkey-cli -h ${PRIMARY_HOST} -p 6379 ping >/dev/null 2>&1; do
    echo "Waiting for primary ${PRIMARY_HOST} to be ready..."
    sleep 5
  done

  echo "Primary is ready, joining cluster..."
  valkey-cli --cluster add-node ${POD_IP}:6379 ${PRIMARY_HOST}:6379 --cluster-replica
else
  echo "This is a primary node. Will join cluster via ${SERVICENAME}-0"
  until valkey-cli -h ${SERVICENAME}-0.${SERVICENAME}.valkey.svc.cluster.local -p 6379 ping 2>/dev/null; do
    echo "Waiting for ${SERVICENAME}-0 to be ready..."
    sleep 5
  done

  echo "Cluster primary is ready, joining cluster..."
  valkey-cli --cluster add-node ${POD_IP}:6379 ${SERVICENAME}-0.${SERVICENAME}.valkey.svc.cluster.local:6379
fi
