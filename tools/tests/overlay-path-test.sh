#!/usr/bin/env bash
set -euo pipefail

error() { :; }
klog() { :; }
warning() { :; }
cl_printf() { :; }

ONPREM="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-adapter.sh"
cd "$ONPREM"

assert_path() {
  local overlay="$1" base="$2" expected="$3"
  SELECTED_OVERLAY="$overlay"
  local got
  got=$(real_get_component_path "$base")
  if [[ "$got" != "$expected" ]]; then
    printf 'FAIL overlay=%s base=%s got=%s expected=%s\n' "$overlay" "$base" "$got" "$expected" >&2
    exit 1
  fi
}

for svc in wd mes production gateway; do
  assert_path demo "k8s/base/plantsuite/${svc}" "k8s/overlays/demo/plantsuite/${svc}"
  assert_path demo "k8s/base/plantsuite/${svc}/" "k8s/overlays/demo/plantsuite/${svc}"
  assert_path production "k8s/base/plantsuite/${svc}" "k8s/overlays/production/plantsuite/${svc}"
  assert_path production "k8s/base/plantsuite/${svc}/" "k8s/overlays/production/plantsuite/${svc}"
  assert_path base "k8s/base/plantsuite/${svc}" "k8s/base/plantsuite/${svc}"
  assert_path base "k8s/base/plantsuite/${svc}/" "k8s/base/plantsuite/${svc}/"
done

printf 'overlay-path tests passed\n'
