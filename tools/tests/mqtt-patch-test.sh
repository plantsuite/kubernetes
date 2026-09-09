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
patch_mes_mqtt_user_env alarms
[[ ! -s "$calls" ]]

: > "$calls"
patch_mes_mqtt_user_env gateway
saved=$(<"$calls")
[[ -n "$saved" ]]
[[ "$saved" == *"set env deployment/gateway"* ]] || [[ "$saved" == *"set env"* ]]
[[ "$saved" == *"TenantId=tenant"* ]]
[[ "$saved" == *"MessageBus__MQTT__User=tenant:system"* ]]

for svc in controlstations mes wd production; do
  : > "$calls"
  patch_mes_mqtt_user_env "$svc"
  saved=$(<"$calls")
  [[ -n "$saved" ]]
  [[ "$saved" == *"set env deployment/${svc}"* ]] || [[ "$saved" == *"set env"* ]]
  [[ "$saved" == *"MessageBus__MQTT__User=tenant:system"* ]]
  [[ "$saved" == *"TenantId=tenant"* ]]
  if [ "$svc" = "mes" ]; then
    [[ "$saved" == *"appsettings_TenantId=tenant"* ]]
    [[ "$saved" == *"appsettings_Mqtt__User=tenant:system"* ]]
  fi
  if [ "$svc" = "wd" ]; then
    [[ "$saved" == *"-c wd-ui appsettings_TenantId=tenant"* ]]
  fi
done

printf 'mqtt-patch tests passed\n'
