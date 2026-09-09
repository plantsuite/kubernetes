#!/usr/bin/env bash
set -euo pipefail

error() { printf '%s\n' "$*" >&2; return 1; }
klog() { :; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/secrets.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"
mkdir -p k8s/base/rabbitmq/plantsuite-rmq
printf 'username=rabbitmq\npassword=test-password\n' > k8s/base/rabbitmq/plantsuite-rmq/.env.secret

sync_rabbitmq_default_user_conf

conf=k8s/base/rabbitmq/plantsuite-rmq/default_user.conf.template
[[ "$(<"$conf")" == $'default_user = rabbitmq\ndefault_pass = test-password' ]]

printf 'rabbitmq default user tests passed\n'
