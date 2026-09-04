#!/usr/bin/env bash
set -euo pipefail

error() { printf '%s\n' "$*" >&2; return 1; }
klog() { :; }
warning() { :; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/secrets.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"
mkdir -p k8s/base/plantsuite/gateway

gw_env="k8s/base/plantsuite/gateway/appsettings.env"
cat > "$gw_env" <<'EOF'
Instance__Id=
Instance__Name=plantsuite-gateway
LocalAuth__Username=admin
LocalAuth__Password=
EOF

kubectl() {
  return 0
}

UPDATE_MODE=false
set +o pipefail
update_gateway_env
set -o pipefail

instance_id=$(get_env_value "$gw_env" "Instance__Id")
instance_name=$(get_env_value "$gw_env" "Instance__Name")
localauth_user=$(get_env_value "$gw_env" "LocalAuth__Username")
localauth_pass=$(get_env_value "$gw_env" "LocalAuth__Password")

[[ -n "$instance_id" ]]
[[ "$instance_id" =~ ^[0-9a-fA-F-]{36}$ ]]
[[ "$instance_name" == "plantsuite-gateway" ]]
[[ "$localauth_user" == "admin" ]]
[[ -n "$localauth_pass" ]]

reset_gateway_env_file
[[ -z "$(get_env_value "$gw_env" "LocalAuth__Password")" ]]
[[ "$(get_env_value "$gw_env" "Instance__Name")" == "plantsuite-gateway" ]]

cat > "$gw_env" <<'EOF'
Instance__Id=
Instance__Name=plantsuite-gateway
LocalAuth__Username=admin
LocalAuth__Password=
EOF

kubectl() {
  if [[ "$*" == *"-o jsonpath="* ]]; then
    printf '%s' "$(printf '%s' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' | base64 -w0 2>/dev/null || printf '%s' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' | base64)"
    return 0
  fi
  return 0
}

set +o pipefail
update_gateway_env
set -o pipefail
[[ "$(get_env_value "$gw_env" "Instance__Id")" == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]]

printf 'gateway-env tests passed\n'
