#!/usr/bin/env bash
set -euo pipefail

error() { printf '%s\n' "$*" >&2; return 1; }
klog() { :; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/secrets.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"
mkdir -p k8s/base/rabbitmq/plantsuite-rmq
env_file=k8s/base/rabbitmq/plantsuite-rmq/.env.secret
printf 'password=test-password\n' > "$env_file"

sync_rabbitmq_default_user_conf

conf=k8s/base/rabbitmq/plantsuite-rmq/default_user.conf.template
[[ "$(get_env_value "$env_file" "username")" == "rabbitmq" ]]
[[ "$(<"$conf")" == $'default_user = rabbitmq\ndefault_pass = test-password' ]]

printf 'username=custom-user\npassword=custom-password\n' > "$env_file"

sync_rabbitmq_default_user_conf

[[ "$(get_env_value "$env_file" "username")" == "custom-user" ]]
[[ "$(<"$conf")" == $'default_user = custom-user\ndefault_pass = custom-password' ]]

printf 'rabbitmq default user tests passed\n'
