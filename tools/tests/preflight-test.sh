#!/usr/bin/env bash
set -euo pipefail

error() { printf '%s\n' "$*" >&2; return 1; }
klog() { :; }
warning() { :; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-adapter.sh"
UPDATE_MODE=false

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"
mkdir -p k8s/base/plantsuite k8s/base/vernemq
export HOME="$tmpdir/home"
mkdir -p "$HOME/.docker"
mkdir -p "$tmpdir/bin"
export PATH="$tmpdir/bin:$PATH"
export SELECTED_OVERLAY=demo

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$tmpdir/key.pem" \
  -out k8s/base/plantsuite/license.crt \
  -days 1 \
  -subj '/O=tenant/CN=plantsuite-test' >/dev/null 2>&1

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$1" == "get" ]]' \
  'read -r server' \
  '[[ "$server" == "plantsuite.azurecr.io" ]]' \
  'printf '\''{"Username":"acr-user","Secret":"acr-password"}\n'\''' \
  > "$tmpdir/bin/docker-credential-test-store"
chmod +x "$tmpdir/bin/docker-credential-test-store"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$1" == "kustomize" ]]' \
  '[[ "${@: -1}" != *"/broken" ]] || { printf "invalid patch\n" >&2; exit 1; }' \
  'printf "apiVersion: v1\nkind: ConfigMap\n"' \
  > "$tmpdir/bin/kubectl"
chmod +x "$tmpdir/bin/kubectl"

printf '{"credsStore":"test-store"}\n' > "$HOME/.docker/config.json"
printf '{"auths":{"plantsuite.azurecr.io":{"auth":""}}}\n' > k8s/base/plantsuite/dockerconfig.json
cp k8s/base/plantsuite/dockerconfig.json k8s/base/vernemq/dockerconfig.json
mkdir -p k8s/overlays/demo/valid
printf 'resources: []\n' > k8s/overlays/demo/valid/kustomization.yaml

real_assert_prereqs
real_dockerconfig_has_registry_auth k8s/base/plantsuite/dockerconfig.json
real_dockerconfig_has_registry_auth k8s/base/vernemq/dockerconfig.json

mkdir -p k8s/overlays/demo/broken
printf 'resources: []\n' > k8s/overlays/demo/broken/kustomization.yaml
if real_assert_prereqs; then
  error 'expected preflight to reject an invalid overlay component'
fi
[[ "$REAL_LAST_ERROR" == *'demo/broken: invalid patch'* ]]
rm -rf k8s/overlays/demo/broken

export PLANTSUITE_ACR_DOCKERCONFIG="$tmpdir/missing-dockerconfig.json"
printf '{"auths":{"plantsuite.azurecr.io":{"auth":""}}}\n' > k8s/base/vernemq/dockerconfig.json
if real_assert_prereqs; then
  error 'expected preflight to reject an empty VerneMQ ACR auth'
fi
[[ "$REAL_LAST_ERROR" == *'k8s/base/vernemq/dockerconfig.json'* ]]

printf 'placeholder\n' > k8s/base/plantsuite/license.crt
if real_assert_prereqs; then
  error 'expected preflight to reject a placeholder license'
fi
[[ "$REAL_LAST_ERROR" == *'certificado de licença inválido'* ]]

UPDATE_MODE=true
real_assert_prereqs

printf 'preflight tests passed\n'
