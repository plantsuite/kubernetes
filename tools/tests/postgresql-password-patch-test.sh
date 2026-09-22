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
mkdir -p k8s/base/plantsuite k8s/base/redis k8s/base/keycloak/plantsuite-kc

cat > k8s/base/plantsuite/.env.secret <<'EOF'
Database__MongoDb__ConnectionString=
Database__Redis__ConnectionString=
Database__Postgresql__ConnectionString=Host=postgres;Database=vernemq;Username=vernemq;Password='old-password'
MessageBus__RabbitMQ__ConnectionString=
MessageBus__RabbitMQ__User=
MessageBus__RabbitMQ__Password=
MessageBus__MQTT__Password=existing-mqtt-password
EOF
printf 'password=redis-password\n' > k8s/base/redis/.env.secret
printf 'client-secret_ps-tenants-admin=admin-secret\nclient-secret_ps-auth-introspection=introspection-secret\n' > k8s/base/keycloak/plantsuite-kc/.env.secret

get_k8s_secret_value() {
  case "$1/$2/$3" in
    mongodb/plantsuite-psmdb-secrets/MONGODB_DATABASE_ADMIN_USER) printf 'mongo-user' ;;
    mongodb/plantsuite-psmdb-secrets/MONGODB_DATABASE_ADMIN_PASSWORD) printf 'mongo-password' ;;
    postgresql/plantsuite-ppgc-pguser-vernemq/password) printf 'new-password' ;;
    rabbitmq/plantsuite-rmq-default-user/username) printf 'rabbit-user' ;;
    rabbitmq/plantsuite-rmq-default-user/password) printf 'rabbit-password' ;;
    *) return 1 ;;
  esac
}

update_plantsuite_env
update_plantsuite_env

pg_conn=$(get_env_value k8s/base/plantsuite/.env.secret Database__Postgresql__ConnectionString)
[[ "$pg_conn" == *"Password='new-password'"* ]]
[[ "$pg_conn" != *old-password* ]]
[[ "$(get_env_value k8s/base/plantsuite/.env.secret JwtOptions__Authority)" == "https://account.plantsuite.local/realms/plantsuite" ]]
[[ "$(get_env_value k8s/base/plantsuite/.env.secret Keycloak__ApiUrl)" == "http://plantsuite-kc-service.keycloak.svc.cluster.local:8080" ]]
[[ "$(get_env_value k8s/base/plantsuite/.env.secret MessageBus__MQTT__Host)" == "plantsuite-vmq.vernemq.svc.cluster.local" ]]
[[ "$(get_env_value k8s/base/plantsuite/.env.secret MessageBus__MQTT__User)" == "system" ]]
[[ "$(get_env_value k8s/base/plantsuite/.env.secret MessageBus__RabbitMQ__Host)" == "plantsuite-rmq.rabbitmq.svc.cluster.local" ]]
[[ "$(get_env_value k8s/base/plantsuite/.env.secret Keycloak__AdminClientId)" == "ps-tenants-admin" ]]
[[ "$(get_env_value k8s/base/plantsuite/.env.secret Keycloak__IntrospectionClientId)" == "ps-auth-introspection" ]]

printf 'JwtOptions__Authority=https://custom.example/realms/plantsuite\r\n' > crlf.env
[[ "$(get_env_value crlf.env JwtOptions__Authority)" == "https://custom.example/realms/plantsuite" ]]

printf 'postgresql-password-patch tests passed\n'
