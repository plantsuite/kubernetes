#!/usr/bin/env bash
set -euo pipefail

error() { printf '%s\n' "$*" >&2; return 1; }
klog() { :; }
warning() { :; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-adapter.sh"

calls=$(mktemp)
trap 'rm -f "$calls"' EXIT

kubectl() {
  printf '%s\n' "$*" >> "$calls"
}

GATEWAY_INFRA_NEVER=(mongodb keycloak redis postgresql)
GATEWAY_INFRA_SKIP=(rabbitmq vernemq metrics-server aspire)
patch_gateway_rabbitmq_env
[[ "$(<"$calls")" == *"set env deployment/gateway -n plantsuite MessageBus__RabbitMQ__ConnectionString="* ]]

: > "$calls"
GATEWAY_INFRA_SKIP=()
patch_gateway_rabbitmq_env
[[ "$(<"$calls")" == *"set env deployment/gateway -n plantsuite MessageBus__RabbitMQ__ConnectionString-"* ]]

printf 'gateway RabbitMQ environment tests passed\n'
