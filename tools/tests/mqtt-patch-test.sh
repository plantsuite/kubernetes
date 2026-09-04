#!/usr/bin/env bash
set -euo pipefail

error() { printf '%s\n' "$*" >&2; return 1; }
klog() { :; }
warning() { :; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/secrets.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"
mkdir -p k8s/base/plantsuite

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$tmpdir/key.pem" \
  -out k8s/base/plantsuite/license.crt \
  -days 1 \
  -subj "/O=tenant/CN=plantsuite-test" >/dev/null 2>&1

extracted=$(extract_tenant_id_from_license)
[[ "$extracted" == "tenant" ]]

calls=$(mktemp)
kubectl() {
  printf '%s\n' "$*" >> "$calls"
  case "$*" in
    *jsonpath='{.spec.replicas}'*) printf '1' ;;
    *jsonpath="{.spec.replicas}"*) printf '1' ;;
    *jsonpath='{.status.readyReplicas}'*) printf '0' ;;
    *jsonpath="{.status.readyReplicas}"*) printf '0' ;;
  esac
  return 0
}

: > "$calls"
patch_mes_mqtt_user_env mes
[[ ! -s "$calls" ]]

: > "$calls"
patch_mes_mqtt_user_env gateway
[[ ! -s "$calls" ]]

for svc in controlstations wd production; do
  : > "$calls"
  patch_mes_mqtt_user_env "$svc"
  saved=$(<"$calls")
  [[ -n "$saved" ]]
  [[ "$saved" == *"set env deployment/${svc}"* ]] || [[ "$saved" == *"set env"* ]]
  [[ "$saved" == *"MessageBus__MQTT__User=tenant:system"* ]]
done

printf 'mqtt-patch tests passed\n'
