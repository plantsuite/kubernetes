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

generated_instance_id=$(generate_gateway_instance_id)
[[ "$generated_instance_id" =~ ^[0-9a-fA-F-]{36}$ ]]

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

cat > "$gw_env" <<'EOF'
Instance__Id=
Instance__Name=
LocalAuth__Username=
LocalAuth__Password=
EOF

kubectl() {
  case "$*" in
    *"Instance__Id"*) printf '%s' "$(printf '%s' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' | base64 -w0)" ;;
    *"Instance__Name"*) printf '%s' "$(printf '%s' 'plantsuite-gateway' | base64 -w0)" ;;
    *"LocalAuth__Username"*) printf '%s' "$(printf '%s' 'admin' | base64 -w0)" ;;
    *"LocalAuth__Password"*) printf '%s' "$(printf '%s' 'gateway-password' | base64 -w0)" ;;
  esac
}

hydrate_gateway_secrets_update
[[ "$(get_env_value "$gw_env" "Instance__Id")" == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]]
[[ "$(get_env_value "$gw_env" "Instance__Name")" == "plantsuite-gateway" ]]
[[ "$(get_env_value "$gw_env" "LocalAuth__Username")" == "admin" ]]
[[ "$(get_env_value "$gw_env" "LocalAuth__Password")" == "gateway-password" ]]

cat > "$gw_env" <<'EOF'
Instance__Id=
Instance__Name=
LocalAuth__Username=
LocalAuth__Password=
EOF

kubectl() {
  case "$*" in
    *"Instance__Name"*) printf '%s' "$(printf '%s' 'plantsuite-gateway' | base64 -w0)" ;;
    *"LocalAuth__Username"*) printf '%s' "$(printf '%s' 'admin' | base64 -w0)" ;;
  esac
}

UPDATE_MODE=true
hydrate_gateway_secrets_update
[[ "$(get_env_value "$gw_env" "Instance__Id")" =~ ^[0-9a-fA-F-]{36}$ ]]
[[ "$(get_env_value "$gw_env" "Instance__Name")" == "plantsuite-gateway" ]]
[[ "$(get_env_value "$gw_env" "LocalAuth__Username")" == "admin" ]]
[[ -n "$(get_env_value "$gw_env" "LocalAuth__Password")" ]]

cat > "$gw_env" <<'EOF'
Instance__Id=
Instance__Name=
LocalAuth__Username=
LocalAuth__Password=
EOF

kubectl() {
  return 0
}

hydrate_gateway_secrets_update
[[ "$(get_env_value "$gw_env" "Instance__Id")" =~ ^[0-9a-fA-F-]{36}$ ]]
[[ "$(get_env_value "$gw_env" "Instance__Name")" == "plantsuite-gateway" ]]
[[ "$(get_env_value "$gw_env" "LocalAuth__Username")" == "admin" ]]
[[ -n "$(get_env_value "$gw_env" "LocalAuth__Password")" ]]

printf 'gateway-env tests passed\n'
