#!/bin/sh
set -e

# Usa variável de ambiente REPLICAS para configuração de cluster
echo "Configurando para ${REPLICAS} replicas"

# Deriva nome do serviço e FQDN do pod do ambiente K8s
SERVICENAME=$(echo ${HOSTNAME} | rev | cut -d'-' -f2- | rev)
if [ -z "${NAMESPACE}" ]; then
  NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "redis")
fi
POD_DNS="${HOSTNAME}.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local"

echo "Pod FQDN: ${POD_DNS}"
echo "Pod IP: ${POD_IP}"

cp /etc/redis/redis.conf /tmp/redis.conf
echo >> /tmp/redis.conf

# Define maxmemory como 80% do limite de memória do container
if [ -n "${MEMORY_LIMIT}" ]; then
  # Analisa valor e unidade de memória
  VALUE=$(echo "${MEMORY_LIMIT}" | sed 's/[a-zA-Z]*$//')
  UNIT=$(echo "${MEMORY_LIMIT}" | sed 's/[0-9]*//')
  case "${UNIT}" in
    Ki) MEMORY_MB=$(awk "BEGIN {print int(${VALUE} * 1024 / 1024 / 1024 * 0.8)}") ;;
    Mi) MEMORY_MB=$(awk "BEGIN {print int(${VALUE} * 0.8)}") ;;
    Gi) MEMORY_MB=$(awk "BEGIN {print int(${VALUE} * 1024 * 0.8)}") ;;
    Ti) MEMORY_MB=$(awk "BEGIN {print int(${VALUE} * 1024 * 1024 * 0.8)}") ;;
    K)  MEMORY_MB=$(awk "BEGIN {print int(${VALUE} / 1000 / 1000 * 0.8)}") ;;
    M)  MEMORY_MB=$(awk "BEGIN {print int(${VALUE} / 1000 * 0.8)}") ;;
    G)  MEMORY_MB=$(awk "BEGIN {print int(${VALUE} * 0.8)}") ;;
    T)  MEMORY_MB=$(awk "BEGIN {print int(${VALUE} * 1000 * 0.8)}") ;;
    *)  MEMORY_MB=$(awk "BEGIN {print int(${VALUE} / 1024 / 1024 * 0.8)}") ;;  # Assuma bytes se não houver unidade
  esac
  echo "maxmemory ${MEMORY_MB}mb" >> /tmp/redis.conf
  echo "maxmemory-policy allkeys-lru" >> /tmp/redis.conf
fi

if [ "${REPLICAS}" -eq "1" ]; then
  sed -i 's/cluster-enabled.*/cluster-enabled no/' /tmp/redis.conf
  echo requirepass "${REDIS_PASSWORD}" >> /tmp/redis.conf
else
  # Habilita cluster para múltiplos nós
  sed -i 's/cluster-enabled.*/cluster-enabled yes/' /tmp/redis.conf
  
  # Anuncia IP e hostname para convergência correta de topologia em restarts
  echo "cluster-announce-ip ${POD_IP}" >> /tmp/redis.conf
  echo "cluster-announce-hostname ${POD_DNS}" >> /tmp/redis.conf
  
  echo requirepass "${REDIS_PASSWORD}" >> /tmp/redis.conf
  echo masterauth "${REDIS_PASSWORD}" >> /tmp/redis.conf
fi
cp /tmp/redis.conf /config/redis.conf || { echo "ERROR: failed to write /config/redis.conf"; exit 1; }
