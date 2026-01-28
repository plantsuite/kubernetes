#!/bin/sh

# Use a variável de ambiente REPLICAS diretamente
echo "Configuring for ${REPLICAS} replicas"

# Derive o nome do serviço e o FQDN do pod (use o namespace do env ou da API downward)
SERVICENAME=$(echo ${HOSTNAME} | rev | cut -d'-' -f2- | rev)
if [ -z "${NAMESPACE}" ]; then
  NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "redis")
fi
POD_DNS="${HOSTNAME}.${SERVICENAME}-nodes.${NAMESPACE}.svc.cluster.local"

echo "Pod FQDN will be: ${POD_DNS}"

cp /etc/redis/redis.conf /tmp/redis.conf
echo >> /tmp/redis.conf  # Garanta uma nova linha no final do arquivo

# Defina maxmemory para 80% do limite de memória do contêiner
if [ -n "${MEMORY_LIMIT}" ]; then
  # Analise o valor e a unidade
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
  # Garanta que o cluster esteja habilitado para multi-nó
  sed -i 's/cluster-enabled.*/cluster-enabled yes/' /tmp/redis.conf
  echo "replica-announce-ip ${POD_DNS}" >> /tmp/redis.conf
  echo "cluster-announce-hostname ${POD_DNS}" >> /tmp/redis.conf
  echo requirepass "${REDIS_PASSWORD}" >> /tmp/redis.conf
  echo masterauth "${REDIS_PASSWORD}" >> /tmp/redis.conf
fi
cp /tmp/redis.conf /config/redis.conf

mkdir -p /data
chown -R 1000:1000 /data
