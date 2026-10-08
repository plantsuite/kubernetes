#!/usr/bin/env bash
set -euo pipefail

error() { printf '%s\n' "$*" >&2; return 1; }
klog() { :; }
warning() { :; }
UPDATE_MODE=false

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/secrets.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"

: > empty.env
[[ -z "$(get_env_value empty.env Missing__Key)" ]]

printf 'JwtOptions__Authority=https://crlf.example/realms/plantsuite\r\n' > crlf.env
[[ "$(get_env_value crlf.env JwtOptions__Authority)" == "https://crlf.example/realms/plantsuite" ]]

mkdir -p k8s/base/plantsuite
cat > k8s/base/plantsuite/.env.secret <<'EOF'
Database__MongoDb__ConnectionString=
EOF
ensure_plantsuite_env_defaults k8s/base/plantsuite/.env.secret
[[ "$(get_env_value k8s/base/plantsuite/.env.secret JwtOptions__Authority)" == "https://account.plantsuite.local/realms/plantsuite" ]]
[[ "$(get_env_value k8s/base/plantsuite/.env.secret MessageBus__MQTT__Host)" == "plantsuite-vmq.vernemq.svc.cluster.local" ]]
set_env_value k8s/base/plantsuite/.env.secret JwtOptions__Authority "https://custom.example/realms/plantsuite"
ensure_plantsuite_env_defaults k8s/base/plantsuite/.env.secret
[[ "$(get_env_value k8s/base/plantsuite/.env.secret JwtOptions__Authority)" == "https://custom.example/realms/plantsuite" ]]

mkdir -p k8s/base/plantsuite/mes k8s/base/plantsuite/wd k8s/base/plantsuite/portal
printf 'ENVIRONMENT=Development\n' > k8s/base/plantsuite/mes/appsettings.env
ensure_mes_appsettings_defaults k8s/base/plantsuite/mes/appsettings.env
[[ "$(get_env_value k8s/base/plantsuite/mes/appsettings.env appsettings_PortalUrl)" == "https://portal.plantsuite.local" ]]
set_env_value k8s/base/plantsuite/mes/appsettings.env appsettings_PortalUrl "https://custom.example"
ensure_mes_appsettings_defaults k8s/base/plantsuite/mes/appsettings.env
[[ "$(get_env_value k8s/base/plantsuite/mes/appsettings.env appsettings_PortalUrl)" == "https://custom.example" ]]

printf 'ENVIRONMENT=Development\n' > k8s/base/plantsuite/wd/appsettings.env
ensure_wd_appsettings_defaults k8s/base/plantsuite/wd/appsettings.env
[[ "$(get_env_value k8s/base/plantsuite/wd/appsettings.env appsettings_PortalUrl)" == "https://portal.plantsuite.local" ]]
set_env_value k8s/base/plantsuite/wd/appsettings.env appsettings_PortalUrl "https://wd.custom.example"
ensure_wd_appsettings_defaults k8s/base/plantsuite/wd/appsettings.env
[[ "$(get_env_value k8s/base/plantsuite/wd/appsettings.env appsettings_PortalUrl)" == "https://wd.custom.example" ]]

printf 'ENVIRONMENT=Development\n' > k8s/base/plantsuite/mes/appsettings.env
printf 'ENVIRONMENT=Development\n' > k8s/base/plantsuite/wd/appsettings.env
printf 'appsettings_Url=https://portal.overlay.local\n' > k8s/base/plantsuite/portal/appsettings.env
ensure_mes_appsettings_defaults k8s/base/plantsuite/mes/appsettings.env
ensure_wd_appsettings_defaults k8s/base/plantsuite/wd/appsettings.env
[[ "$(get_env_value k8s/base/plantsuite/mes/appsettings.env appsettings_PortalUrl)" == "https://portal.overlay.local" ]]
[[ "$(get_env_value k8s/base/plantsuite/wd/appsettings.env appsettings_PortalUrl)" == "https://portal.overlay.local" ]]

generated_instance_id=$(generate_gateway_instance_id)
[[ "$generated_instance_id" =~ ^[0-9a-fA-F-]{36}$ ]]

tui_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common/tui.sh"
TUI_PLAIN=1 bash -c 'source "$1"; [[ "$TUI_PLAIN" == "1" ]]' _ "$tui_file"
env -u TUI_PLAIN bash -c 'source "$1"; [[ "$TUI_PLAIN" == "0" ]]' _ "$tui_file"

printf 'shell-portability tests passed\n'
