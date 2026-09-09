#!/usr/bin/env bash
set -euo pipefail

ONPREM="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ONPREM"

services=(wd mes production gateway)
overlays=(base demo production)

expect_image_names_for() {
  local svc="$1"
  case "$svc" in
    wd) printf '%s\n' "plantsuite.azurecr.io/wd-api:" "plantsuite.azurecr.io/plantsuite-wd:" ;;
    mes) printf '%s\n' "plantsuite.azurecr.io/plantsuite-mes:" ;;
    production) printf '%s\n' "plantsuite.azurecr.io/production-api:" ;;
    gateway) printf '%s\n' "plantsuite.azurecr.io/gateway-api:" "plantsuite.azurecr.io/plantsuite-gateway:" ;;
  esac
}

path_for() {
  local overlay="$1" svc="$2"
  if [[ "$overlay" == "base" ]]; then
    printf 'k8s/base/plantsuite/%s' "$svc"
  else
    printf 'k8s/overlays/%s/plantsuite/%s' "$overlay" "$svc"
  fi
}

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

for svc in "${services[@]}"; do
  for overlay in "${overlays[@]}"; do
    path=$(path_for "$overlay" "$svc")
    rendered=$(kubectl kustomize "$path") || fail "kubectl kustomize $path"

    echo "$rendered" | grep -q 'plantsuite\.local' || fail "$path missing .plantsuite.local hosts"

    if echo "$rendered" | grep -Eq 'mes\.dev|\.dev\.plantsuite\.com|mqttdev\.plantsuite\.com'; then
      fail "$path contains legacy dev hosts"
    fi

    image_lines=$(echo "$rendered" | grep -E '^[[:space:]]*image:[[:space:]]')

    if echo "$image_lines" | grep -Eq 'plantsuite-wd-ui|plantsuite-production|plantsuite-gateway-ui'; then
      fail "$path contains legacy image names"
    fi

    while IFS= read -r img; do
      echo "$image_lines" | grep -F "$img" | grep -Eq ':v?[0-9]|:pr-' || fail "$path missing pinned image $img"
    done < <(expect_image_names_for "$svc")

    if echo "$image_lines" | grep -q ':latest'; then
      fail "$path still renders :latest image tags"
    fi
  done
done

rabbitmq_rendered=$(kubectl kustomize k8s/base/rabbitmq/plantsuite-rmq) || fail "kubectl kustomize rabbitmq"
echo "$rabbitmq_rendered" | grep -q 'default_user.conf:' || fail "rabbitmq render missing default_user.conf"

printf 'kustomize-mes-gateway tests passed\n'
