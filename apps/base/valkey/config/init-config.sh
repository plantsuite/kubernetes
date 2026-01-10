#!/bin/sh

# Use the REPLICAS environment variable directly
echo "Configuring for ${REPLICAS} replicas"

cp /etc/valkey/valkey.conf /tmp/valkey.conf
if [ "${REPLICAS}" -eq "1" ]; then
  sed -i 's/cluster-enabled yes/cluster-enabled no/' /tmp/valkey.conf
  echo requirepass "${VALKEY_PASSWORD}" >> /tmp/valkey.conf
else
  # Ensure cluster is enabled for multi-node
  sed -i 's/cluster-enabled no/cluster-enabled yes/' /tmp/valkey.conf
  echo "replica-announce-ip ${POD_IP}" >> /tmp/valkey.conf
  echo "cluster-announce-ip ${POD_IP}" >> /tmp/valkey.conf
  echo requirepass "${VALKEY_PASSWORD}" >> /tmp/valkey.conf
  echo primaryauth "${VALKEY_PASSWORD}" >> /tmp/valkey.conf
fi
cp /tmp/valkey.conf /config/valkey.conf

mkdir -p /data
chown -R 1000:1000 /data
