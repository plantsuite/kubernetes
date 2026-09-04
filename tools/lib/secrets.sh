#!/usr/bin/env bash
# =============================================================================
# secrets.sh — Geração e sincronização de secrets nos arquivos .env.secret
#
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/lib/secrets.sh"
#
# Depende de: klog, warning, error  (definidos em install.sh)
# Depende de: UPDATE_MODE           (variável global de install.sh)
# =============================================================================

# Helper sed portátil para edição in-place
# Uso: sed_inplace '<script-sed>' <arquivo>
sed_inplace() {
  if [ "$#" -lt 2 ]; then
    echo "uso: sed_inplace <script> <arquivo>" >&2
    return 2
  fi
  local script="$1"; shift
  local file="$1"

  if [ ! -f "$file" ]; then
    echo "arquivo não encontrado: $file" >&2
    return 3
  fi

  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 4

  sed -e "$script" "$file" > "$tmp" || { rm -f "$tmp"; return 5; }

  mv "$tmp" "$file"
}

# Atualiza chave em um arquivo .env (cria se não existir)
set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local status

  [ -f "$file" ] || touch "$file"
  export _AWK_KEY="$key" _AWK_VALUE="$value"
  awk \
    'BEGIN{updated=0; key=ENVIRON["_AWK_KEY"]; value=ENVIRON["_AWK_VALUE"]}
     $0 ~ ("^"key"=") {print key"="value; updated=1; next}
     {print}
     END{if(updated==0){print key"="value}}' \
    "$file" > "$file.tmp" && chmod 0600 "$file.tmp" && mv "$file.tmp" "$file"
  status=$?
  unset _AWK_KEY _AWK_VALUE
  return "$status"
}

# Lê uma chave de arquivo .env (retorna vazio se não existir)
get_env_value() {
  local file="$1"
  local key="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi
  grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2-
}

# Lê uma chave de Secret do Kubernetes (retorna vazio em falha/ausência)
get_k8s_secret_value() {
  local namespace="$1"
  local secret_name="$2"
  local data_key="$3"
  kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.${data_key}}" 2>/dev/null | base64 -d | tr -d '\r'
}

_MONGO_CONN_FMT='mongodb://%s@plantsuite-psmdb-rs0.mongodb.svc.cluster.local:27017/?authSource=admin&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=true&w=majority'
_REDIS_CONN_FMT='plantsuite-redis.redis.svc.cluster.local,password=%s'
_PG_CONN_FMT='Host=plantsuite-ppgc-pgbouncer.postgresql.svc.cluster.local;Port=5432;Database=vernemq;Username=vernemq;Password=%s;Minimum Pool Size=10;Maximum Pool Size=10'
_RMQ_CONN_FMT='amqp://%s@plantsuite-rmq.rabbitmq.svc.cluster.local:5672/'

sanitize_env_file() {
  local file="$1"
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    return 0
  fi

  local keys_to_delete=""
  while IFS= read -r line; do
    case "$line" in
      [a-z]*=*)
        local key="${line%%=*}"
        local escaped_key
        printf -v escaped_key '%s' "$key" | sed 's/[.[*?^$()+]/\\&/g'
        if [[ -z "$keys_to_delete" ]]; then
          keys_to_delete="$escaped_key"
        else
          keys_to_delete="${keys_to_delete}\|$escaped_key"
        fi
        ;;
    esac
  done < "$file"

  if [[ -n "$keys_to_delete" ]]; then
    warning "Removendo chaves corrompidas do $file"
    sed_inplace "/^\(${keys_to_delete}\)=/d" "$file" 2>/dev/null || true
    warning "Arquivo $file limpo. Por favor, execute o instalador novamente."
  fi
  return 0
}

# Atualiza arquivos dependentes quando a senha do Redis mudar.
sync_redis_password_dependents() {
  local redis_password="$1"
  [ -z "$redis_password" ] && return 0

  # PlantSuite usa Redis connection string
  local plantsuite_env="k8s/base/plantsuite/.env.secret"
  if [ -f "$plantsuite_env" ]; then
    local existing_redis_conn redis_conn
    existing_redis_conn=$(get_env_value "$plantsuite_env" "Database__Redis__ConnectionString")
    if [ -n "$existing_redis_conn" ]; then
      if echo "$existing_redis_conn" | grep -q "password="; then
        redis_conn=$(echo "$existing_redis_conn" | sed "s|password=[^,]*|password=${redis_password}|")
      else
        redis_conn="${existing_redis_conn},password=${redis_password}"
      fi
    else
      redis_conn="plantsuite-redis.redis.svc.cluster.local,password=${redis_password}"
    fi
    set_env_value "$plantsuite_env" "Database__Redis__ConnectionString" "$redis_conn"
  fi
}

# Atualiza dependentes quando os client secrets do Keycloak mudarem.
sync_keycloak_client_secrets_dependents() {
  local tenants_admin_secret="$1"
  local introspection_secret="$2"
  [ -z "$tenants_admin_secret" ] && return 0
  [ -z "$introspection_secret" ] && return 0

  local plantsuite_env="k8s/base/plantsuite/.env.secret"
  if [ -f "$plantsuite_env" ]; then
    set_env_value "$plantsuite_env" "Keycloak__AdminClientSecret" "$tenants_admin_secret"
    set_env_value "$plantsuite_env" "Keycloak__IntrospectionClientSecret" "$introspection_secret"
  fi
}

# Função para gerar senha segura e atualizar .env.secret
generate_secure_password() {
  local env_file="$1"
  local key="$2"
  local length="${3:-32}"

  local existing_password=""
  if [ -f "$env_file" ]; then
    existing_password=$(grep "^${key}=" "$env_file" 2>/dev/null | cut -d'=' -f2)
  fi

  if [ "$UPDATE_MODE" = true ] && [ -n "$existing_password" ]; then
    klog "Modo update: preservando senha existente em $env_file"
    return 0
  fi

  klog "Gerando senha segura..."

  local password="$existing_password"
  if [ -z "$password" ]; then
    password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length")

    if [ -z "$password" ]; then
      error "Não foi possível gerar senha."
      return 1
    fi
  fi

  set_env_value "$env_file" "$key" "$password"

  # Redis é dependência de VerneMQ e PlantSuite: sincroniza os .env.secret locais.
  if [ "$env_file" = "k8s/base/redis/.env.secret" ] && [ "$key" = "password" ]; then
    sync_redis_password_dependents "$password"
  fi

  klog "Senha gerada e atualizada em $env_file"
}

# Função para atualizar .env.secret do keycloak com credenciais do PostgreSQL e client secrets
update_keycloak_secrets() {
  local secret_name="plantsuite-ppgc-pguser-keycloak"
  local namespace="postgresql"
  local env_file="k8s/base/keycloak/plantsuite-kc/.env.secret"

  local existing_db_username="" existing_db_password="" existing_auth_secret="" existing_tenants_secret=""
  if [ -f "$env_file" ]; then
    existing_db_username=$(get_env_value "$env_file" "db_username")
    existing_db_password=$(get_env_value "$env_file" "db_password")
    existing_auth_secret=$(get_env_value "$env_file" "client-secret_ps-auth-introspection")
    existing_tenants_secret=$(get_env_value "$env_file" "client-secret_ps-tenants-admin")
  fi

  if [ "$UPDATE_MODE" = true ] && [ -n "$existing_db_username" ] && [ -n "$existing_db_password" ] && [ -n "$existing_auth_secret" ] && [ -n "$existing_tenants_secret" ]; then
    klog "Modo update: preservando secrets existentes do Keycloak"
    return 0
  fi

  klog "Obtendo credenciais do banco de dados para o Keycloak..."

  # Fonte da verdade para db_username/db_password: Secret gerado pelo PostgreSQL.
  # Isso evita reaproveitar credenciais antigas de .env.secret em instalação nova.
  local db_username db_password
  db_username=$(get_k8s_secret_value "$namespace" "$secret_name" "user")
  db_password=$(get_k8s_secret_value "$namespace" "$secret_name" "password")

  if [ -z "$db_username" ] || [ -z "$db_password" ]; then
    if [ "$UPDATE_MODE" = true ] && [ -n "$existing_db_username" ] && [ -n "$existing_db_password" ]; then
      warning "Secret $namespace/$secret_name indisponível; preservando credenciais locais do Keycloak em modo update."
      db_username="$existing_db_username"
      db_password="$existing_db_password"
    else
      error "Não foi possível obter as credenciais do secret $secret_name no namespace $namespace."
      return 1
    fi
  fi

  local auth_introspection_secret="$existing_auth_secret"
  local tenants_admin_secret="$existing_tenants_secret"

  set_env_value "$env_file" "db_username" "$db_username"
  set_env_value "$env_file" "db_password" "$db_password"
  generate_secure_password "$env_file" "client-secret_ps-auth-introspection"
  generate_secure_password "$env_file" "client-secret_ps-tenants-admin"

  # Recarrega os valores efetivos após geração/preservação.
  auth_introspection_secret=$(get_env_value "$env_file" "client-secret_ps-auth-introspection")
  tenants_admin_secret=$(get_env_value "$env_file" "client-secret_ps-tenants-admin")

  # Mantém PlantSuite alinhado aos client secrets mais recentes do Keycloak.
  sync_keycloak_client_secrets_dependents "$tenants_admin_secret" "$auth_introspection_secret"

  klog "Credenciais do banco de dados atualizadas em $env_file"
}

# Função para obter as credenciais do PostgreSQL e atualizar o .env.secret do VerneMQ
update_vernemq_secrets() {
  local env_file="k8s/base/vernemq/.env.secret"

  sanitize_env_file "$env_file"
  local existing_postgres_host="" existing_postgres_user="" existing_postgres_password=""
  if [ -f "$env_file" ]; then
    existing_postgres_host=$(grep "^DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__HOST=" "$env_file" 2>/dev/null | cut -d'=' -f2-)
    existing_postgres_user=$(grep "^DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__USER=" "$env_file" 2>/dev/null | cut -d'=' -f2-)
    existing_postgres_password=$(grep "^DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__PASSWORD=" "$env_file" 2>/dev/null | cut -d'=' -f2-)
  fi

  if [ "$UPDATE_MODE" = true ] && [ -n "$existing_postgres_host" ] && [ -n "$existing_postgres_user" ] && [ -n "$existing_postgres_password" ]; then
    klog "Modo update: preservando secrets existentes do VerneMQ"
    return 0
  fi

  klog "Obtendo credenciais do PostgreSQL para o VerneMQ..."

  local secret_name="plantsuite-ppgc-pguser-vernemq"
  local namespace="postgresql"
  local postgres_host="plantsuite-ppgc-pgbouncer.postgresql.svc.cluster.local"
  local postgres_user postgres_password

  postgres_user=$(get_k8s_secret_value "$namespace" "$secret_name" "user")
  postgres_password=$(get_k8s_secret_value "$namespace" "$secret_name" "password")

  if [ -z "$postgres_user" ] || [ -z "$postgres_password" ]; then
    if [ "$UPDATE_MODE" = true ] && [ -n "$existing_postgres_user" ] && [ -n "$existing_postgres_password" ]; then
      warning "Secret $namespace/$secret_name indisponível; preservando credenciais locais do VerneMQ em modo update."
      postgres_host="${existing_postgres_host:-postgres_host}"
      postgres_user="$existing_postgres_user"
      postgres_password="$existing_postgres_password"
    else
      error "Não foi possível obter as credenciais do secret $secret_name no namespace $namespace."
      return 1
    fi
  fi

  if [ ! -f "$env_file" ]; then
    error "Arquivo $env_file não encontrado."
    return 1
  fi

  set_env_value "$env_file" "DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__HOST" "$postgres_host"
  set_env_value "$env_file" "DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__USER" "$postgres_user"
  set_env_value "$env_file" "DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__PASSWORD" "$postgres_password"

  klog "Credenciais do PostgreSQL atualizadas no VerneMQ com sucesso."
}

# Função para atualizar k8s/base/plantsuite/.env.secret com segredos de MongoDB, RabbitMQ, Keycloak e gerar senha MQTT
update_plantsuite_env() {
  local env_file="k8s/base/plantsuite/.env.secret"

  klog "Atualizando .env.secret do Plantsuite com segredos do cluster..."
  sanitize_env_file "$env_file"

  local mongo_user="" mongo_pass=""
  local existing_mongo_conn
  existing_mongo_conn=$(get_env_value "$env_file" "Database__MongoDb__ConnectionString")

  # Fonte da verdade: Secret gerado pelo MongoDB Operator.
  mongo_user=$(get_k8s_secret_value "mongodb" "plantsuite-psmdb-secrets" "MONGODB_DATABASE_ADMIN_USER")
  mongo_pass=$(get_k8s_secret_value "mongodb" "plantsuite-psmdb-secrets" "MONGODB_DATABASE_ADMIN_PASSWORD")

  if [ -z "$mongo_user" ] || [ -z "$mongo_pass" ]; then
    # Fallback UPDATE_MODE: extrai credenciais da connection string local existente.
    if [ "$UPDATE_MODE" = true ] && [ -n "$existing_mongo_conn" ] && echo "$existing_mongo_conn" | grep -q 'mongodb://[^:@]*:[^@]*@'; then
      warning "mongodb/plantsuite-psmdb-secrets indisponível; extraindo credenciais da connection string local em modo update."
      mongo_user=$(echo "$existing_mongo_conn" | sed -n 's|^.*mongodb://\([^:@]*\):\([^@]*\)@.*$|\1|p')
      mongo_pass=$(echo "$existing_mongo_conn" | sed -n 's|^.*mongodb://\([^:@]*\):\([^@]*\)@.*$|\2|p')
    fi
  fi
  if [ -z "$mongo_user" ] || [ -z "$mongo_pass" ]; then
    error "Não foi possível obter credenciais do MongoDB em mongodb/plantsuite-psmdb-secrets."
    return 1
  fi

  local mongo_conn

  if [ -n "$existing_mongo_conn" ] && echo "$existing_mongo_conn" | grep -q "mongodb://"; then
    if echo "$existing_mongo_conn" | grep -q "@"; then
      mongo_conn=$(echo "$existing_mongo_conn" | sed "s|mongodb://[^@]*@|mongodb://${mongo_user}:${mongo_pass}@|")
    else
      mongo_conn=$(echo "$existing_mongo_conn" | sed "s|mongodb://|mongodb://${mongo_user}:${mongo_pass}@|")
    fi
  else
    printf -v mongo_conn "$_MONGO_CONN_FMT" "${mongo_user}:${mongo_pass}"
  fi
  set_env_value "$env_file" "Database__MongoDb__ConnectionString" "$mongo_conn"

  local redis_pass
  # Preferência: .env.secret local -> Secret no cluster
  redis_pass=$(get_env_value "k8s/base/redis/.env.secret" "password")
  if [ -z "$redis_pass" ]; then
    redis_pass=$(get_k8s_secret_value "redis" "plantsuite-redis-env" "password")
  fi
  if [ -z "$redis_pass" ]; then
    error "Não foi possível obter a senha do Redis para montar a connection string do Redis."
    return 1
  fi

  local redis_conn existing_redis_conn
  existing_redis_conn=$(grep "^Database__Redis__ConnectionString=" "$env_file" 2>/dev/null | cut -d'=' -f2-)

  if [ -n "$existing_redis_conn" ]; then
    if echo "$existing_redis_conn" | grep -q "password="; then
      redis_conn=$(echo "$existing_redis_conn" | sed "s|password=[^,]*|password=${redis_pass}|")
    else
      redis_conn="${existing_redis_conn},password=${redis_pass}"
    fi
  else
    printf -v redis_conn "$_REDIS_CONN_FMT" "$redis_pass"
  fi
  set_env_value "$env_file" "Database__Redis__ConnectionString" "$redis_conn"

  local pg_pass
  local existing_pg_conn
  existing_pg_conn=$(grep "^Database__Postgresql__ConnectionString=" "$env_file" 2>/dev/null | cut -d'=' -f2-)
  pg_pass=$(get_k8s_secret_value "postgresql" "plantsuite-ppgc-pguser-vernemq" "password")
  if [ -z "$pg_pass" ]; then
    if [ "$UPDATE_MODE" = true ] && [ -n "$existing_pg_conn" ] && echo "$existing_pg_conn" | grep -q "Password="; then
      warning "postgresql/plantsuite-ppgc-pguser-vernemq indisponível; preservando senha local do PostgreSQL em modo update."
      pg_pass=$(echo "$existing_pg_conn" | sed -n "s|.*Password='\([^']*\)'.*|\1|p")
      if [ -z "$pg_pass" ]; then
        pg_pass=$(echo "$existing_pg_conn" | sed -n 's|.*Password=\([^;]*\).*|\1|p')
      fi
    fi
  fi
  if [ -z "$pg_pass" ]; then
    error "Não foi possível obter a senha do PostgreSQL em postgresql/plantsuite-ppgc-pguser-vernemq."
    return 1
  fi

  local pg_conn
  local pg_pass_quoted="${pg_pass//\'/\'\'}"
  if [ -n "$existing_pg_conn" ]; then
    if echo "$existing_pg_conn" | grep -q "Password="; then
      pg_conn=$(echo "$existing_pg_conn" | sed "s|Password=[^;']*|Password='${pg_pass_quoted}'|")
    else
      pg_conn="${existing_pg_conn};Password='${pg_pass_quoted}'"
    fi
  else
    printf -v pg_conn "$_PG_CONN_FMT" "'${pg_pass_quoted}'"
  fi
  set_env_value "$env_file" "Database__Postgresql__ConnectionString" "$pg_conn"

  local rmq_user rmq_pass
  local existing_rmq_user existing_rmq_pass
  existing_rmq_user=$(get_env_value "$env_file" "MessageBus__RabbitMQ__User")
  existing_rmq_pass=$(get_env_value "$env_file" "MessageBus__RabbitMQ__Password")
  # Fonte da verdade: Secret gerado pelo RabbitMQ Operator.
  rmq_user=$(get_k8s_secret_value "rabbitmq" "plantsuite-rmq-default-user" "username")
  rmq_pass=$(get_k8s_secret_value "rabbitmq" "plantsuite-rmq-default-user" "password")
  if [ -z "$rmq_user" ] || [ -z "$rmq_pass" ]; then
    if [ "$UPDATE_MODE" = true ] && [ -n "$existing_rmq_user" ] && [ -n "$existing_rmq_pass" ]; then
      warning "rabbitmq/plantsuite-rmq-default-user indisponível; preservando credenciais locais em modo update."
      rmq_user="$existing_rmq_user"
      rmq_pass="$existing_rmq_pass"
    else
      error "Não foi possível obter usuário/senha do RabbitMQ em rabbitmq/plantsuite-rmq-default-user."
      return 1
    fi
  fi

  local rmq_conn existing_rmq_conn
  existing_rmq_conn=$(get_env_value "$env_file" "MessageBus__RabbitMQ__ConnectionString")
  if [ -n "$existing_rmq_conn" ] && echo "$existing_rmq_conn" | grep -q "amqp://"; then
    if echo "$existing_rmq_conn" | grep -q "@"; then
      rmq_conn=$(echo "$existing_rmq_conn" | sed "s|amqp://[^@]*@|amqp://${rmq_user}:${rmq_pass}@|")
    else
      rmq_conn=$(echo "$existing_rmq_conn" | sed "s|amqp://|amqp://${rmq_user}:${rmq_pass}@|")
    fi
  else
    printf -v rmq_conn "$_RMQ_CONN_FMT" "${rmq_user}:${rmq_pass}"
  fi

  set_env_value "$env_file" "MessageBus__RabbitMQ__ConnectionString" "$rmq_conn"
  set_env_value "$env_file" "MessageBus__RabbitMQ__User" "$rmq_user"
  set_env_value "$env_file" "MessageBus__RabbitMQ__Password" "$rmq_pass"

  generate_secure_password "$env_file" "MessageBus__MQTT__Password"

  local kc_admin kc_intro
  # Preferência: .env.secret local do Keycloak -> Secret no cluster
  kc_admin=$(get_env_value "k8s/base/keycloak/plantsuite-kc/.env.secret" "client-secret_ps-tenants-admin")
  kc_intro=$(get_env_value "k8s/base/keycloak/plantsuite-kc/.env.secret" "client-secret_ps-auth-introspection")
  if [ -z "$kc_admin" ]; then
    kc_admin=$(get_k8s_secret_value "keycloak" "keycloak" "client-secret_ps-tenants-admin")
  fi
  if [ -z "$kc_intro" ]; then
    kc_intro=$(get_k8s_secret_value "keycloak" "keycloak" "client-secret_ps-auth-introspection")
  fi
  if [ -z "$kc_admin" ] || [ -z "$kc_intro" ]; then
    error "Não foi possível obter client secrets do Keycloak em keycloak/keycloak."
    return 1
  fi
  set_env_value "$env_file" "Keycloak__AdminClientSecret" "$kc_admin"
  set_env_value "$env_file" "Keycloak__IntrospectionClientSecret" "$kc_intro"

  klog "Arquivo atualizado: $env_file"
}

update_gateway_env() {
  local gw_env_file="k8s/base/plantsuite/gateway/appsettings.env"

  klog "Atualizando secrets do gateway..."
  sanitize_env_file "$gw_env_file"

  local instance_id instance_name localauth_user
  instance_id=$(get_env_value "$gw_env_file" "Instance__Id")
  instance_name=$(get_env_value "$gw_env_file" "Instance__Name")
  localauth_user=$(get_env_value "$gw_env_file" "LocalAuth__Username")

  if [ -z "$instance_id" ]; then
    # Tenta preservar UUID do secret existente no cluster (evita divergência com o SQLite)
    instance_id=$(kubectl get secret plantsuite-gateway-env -n plantsuite \
      -o jsonpath='{.data.Instance__Id}' 2>/dev/null | base64 -d 2>/dev/null | tr -d '[:space:]')
  fi
  if [ -z "$instance_id" ]; then
    instance_id=$(cat /proc/sys/kernel/random/uuid)
  fi
  if [ -z "$instance_id" ]; then
    error "Não foi possível gerar UUID para Instance__Id do gateway."
    return 1
  fi

  if [ -z "$instance_name" ]; then
    error "Instance__Name do gateway não configurado. Defina o valor em k8s/base/plantsuite/gateway/appsettings.env antes de instalar."
    return 1
  fi

  [ -z "$localauth_user" ] && localauth_user="admin"

  generate_secure_password "$gw_env_file" "LocalAuth__Password"

  set_env_value "$gw_env_file" "Instance__Id" "$instance_id"
  set_env_value "$gw_env_file" "Instance__Name" "$instance_name"
  set_env_value "$gw_env_file" "LocalAuth__Username" "$localauth_user"

  klog "Arquivo atualizado: $gw_env_file"
}

secret_data_exists() {
  local namespace="$1"
  local secret_name="$2"
  local data_key="$3"
  local raw
  raw=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.${data_key}}" 2>/dev/null)
  [ -n "$raw" ]
}

_HYDRATE_CTX=""

hydrate_kv() {
  local ns="$1" secret="$2" key="$3" file="$4" out_key="${5:-$key}"
  if ! secret_data_exists "$ns" "$secret" "$key"; then
    error "Hidratacao ${_HYDRATE_CTX} bloqueada: chave ${key} ausente em ${ns}/${secret} (RBAC, Secret ou valor)."
    return 1
  fi
  local val
  val=$(get_k8s_secret_value "$ns" "$secret" "$key")
  if [ -z "$val" ]; then
    error "Hidratacao ${_HYDRATE_CTX} bloqueada: ${key} vazio em ${ns}/${secret}."
    return 1
  fi
  set_env_value "$file" "$out_key" "$val"
}

hydrate_mongodb_secrets_update() {
  local file="k8s/base/mongodb/plantsuite-psmdb/.env.secret"
  local ns="mongodb"
  local secret="plantsuite-psmdb-secrets"
  local role
  _HYDRATE_CTX="mongodb"
  for role in DATABASE_ADMIN CLUSTER_ADMIN CLUSTER_MONITOR USER_ADMIN BACKUP; do
    hydrate_kv "$ns" "$secret" "MONGODB_${role}_USER" "$file" || return $?
    hydrate_kv "$ns" "$secret" "MONGODB_${role}_PASSWORD" "$file" || return $?
  done
  klog "Hidratado: $file (a partir de ${ns}/${secret})"
}

hydrate_postgresql_secrets_update() {
  local dir="k8s/base/postgresql/plantsuite-ppgc"
  local ns="postgresql"
  local user env_file
  _HYDRATE_CTX="postgresql"
  for user in postgres keycloak vernemq; do
    env_file="${dir}/.env-${user}.secret"
    hydrate_kv "$ns" "plantsuite-ppgc-pguser-${user}" "password" "$env_file" || return $?
  done
  klog "Hidratado: ${dir}/.env-{postgres,keycloak,vernemq}.secret (a partir de ${ns})"
}

hydrate_redis_secrets_update() {
  local file="k8s/base/redis/.env.secret"
  local ns="redis"
  local secret="plantsuite-redis-env"
  _HYDRATE_CTX="redis"
  hydrate_kv "$ns" "$secret" "password" "$file" || return $?
  klog "Hidratado: $file (a partir de ${ns}/${secret})"
}

hydrate_rabbitmq_secrets_update() {
  local file="k8s/base/rabbitmq/plantsuite-rmq/.env.secret"
  local ns="rabbitmq"
  local secret="plantsuite-rmq-default-user"
  _HYDRATE_CTX="rabbitmq"
  hydrate_kv "$ns" "$secret" "username" "$file" || return $?
  hydrate_kv "$ns" "$secret" "password" "$file" || return $?
  klog "Hidratado: $file (a partir de ${ns}/${secret})"
}

hydrate_keycloak_secrets_update() {
  local file="k8s/base/keycloak/plantsuite-kc/.env.secret"
  local ns="keycloak"
  local secret="keycloak"
  _HYDRATE_CTX="keycloak"
  hydrate_kv "$ns" "$secret" "db_username" "$file" || return $?
  hydrate_kv "$ns" "$secret" "db_password" "$file" || return $?
  hydrate_kv "$ns" "$secret" "client-secret_ps-auth-introspection" "$file" || return $?
  hydrate_kv "$ns" "$secret" "client-secret_ps-tenants-admin" "$file" || return $?
  klog "Hidratado: $file (a partir de ${ns}/${secret})"
}

hydrate_vernemq_secrets_update() {
  local file="k8s/base/vernemq/.env.secret"
  local ns="postgresql"
  local secret="plantsuite-ppgc-pguser-vernemq"
  _HYDRATE_CTX="vernemq"
  hydrate_kv "$ns" "$secret" "password" "$file" "DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__PASSWORD" || return $?
  klog "Hidratado: $file (a partir de ${ns}/${secret})"
}

hydrate_plantsuite_deps_update() {
  hydrate_mongodb_secrets_update || return $?
  hydrate_postgresql_secrets_update || return $?
  hydrate_redis_secrets_update || return $?
  hydrate_rabbitmq_secrets_update || return $?
  hydrate_keycloak_secrets_update || return $?
  hydrate_vernemq_secrets_update || return $?
  return 0
}

hydrate_gateway_secrets_update() {
  local gw_env_file="k8s/base/plantsuite/gateway/appsettings.env"
  local ns="plantsuite"
  local secret="plantsuite-gateway-env"
  local pass_val

  if ! secret_data_exists "$ns" "$secret" "LocalAuth__Password"; then
    error "Hidratacao gateway bloqueada: chave LocalAuth__Password ausente em ${ns}/${secret} (RBAC, Secret ou valor)."
    return 1
  fi
  pass_val=$(get_k8s_secret_value "$ns" "$secret" "LocalAuth__Password")
  if [ -z "$pass_val" ]; then
    error "Hidratacao gateway bloqueada: LocalAuth__Password vazio em ${ns}/${secret}."
    return 1
  fi
  set_env_value "$gw_env_file" "LocalAuth__Password" "$pass_val"
  klog "Hidratado: $gw_env_file (a partir de ${ns}/${secret})"
}

hydrate_plantsuite_env_file_update() {
  local file="k8s/base/plantsuite/.env.secret"
  local ns="plantsuite"
  local secret="plantsuite-env"
  local key val

  for key in Database__MongoDb__ConnectionString Database__Redis__ConnectionString Database__Postgresql__ConnectionString MessageBus__RabbitMQ__ConnectionString MessageBus__RabbitMQ__User MessageBus__RabbitMQ__Password MessageBus__MQTT__Password Keycloak__AdminClientSecret Keycloak__IntrospectionClientSecret SMTP__Password; do
    if ! secret_data_exists "$ns" "$secret" "$key"; then
      error "Hidratacao plantsuite bloqueada: chave ${key} ausente em ${ns}/${secret} (RBAC, Secret ou valor)."
      return 1
    fi
    val=$(get_k8s_secret_value "$ns" "$secret" "$key")
    if [ -z "$val" ]; then
      error "Hidratacao plantsuite bloqueada: valor vazio para ${key} em ${ns}/${secret}."
      return 1
    fi
    set_env_value "$file" "$key" "$val"
  done
  klog "Hidratado: $file (a partir de ${ns}/${secret})"
}

hydrate_secrets_for_update() {
  local step_id="$1"
  case "$step_id" in
    mongodb-instance)
      hydrate_mongodb_secrets_update || return $?
      ;;
    postgresql-instance)
      hydrate_postgresql_secrets_update || return $?
      ;;
    redis)
      hydrate_redis_secrets_update || return $?
      ;;
    rabbitmq-instance)
      hydrate_rabbitmq_secrets_update || return $?
      ;;
    keycloak-instance)
      hydrate_keycloak_secrets_update || return $?
      ;;
    vernemq)
      hydrate_vernemq_secrets_update || return $?
      ;;
    plantsuite-base)
      hydrate_plantsuite_deps_update || return $?
      hydrate_plantsuite_env_file_update || return $?
      hydrate_gateway_secrets_update || return $?
      ;;
    *)
      return 0
      ;;
  esac
  return 0
}

reset_mongodb_env_file() {
  local file="k8s/base/mongodb/plantsuite-psmdb/.env.secret"
  [ -f "$file" ] || return 0
  local status=0
  set_env_value "$file" "MONGODB_DATABASE_ADMIN_PASSWORD" "" || status=1
  set_env_value "$file" "MONGODB_CLUSTER_ADMIN_PASSWORD" "" || status=1
  set_env_value "$file" "MONGODB_CLUSTER_MONITOR_PASSWORD" "" || status=1
  set_env_value "$file" "MONGODB_USER_ADMIN_PASSWORD" "" || status=1
  set_env_value "$file" "MONGODB_BACKUP_PASSWORD" "" || status=1
  return "$status"
}

reset_postgres_env_files() {
  local dir="k8s/base/postgresql/plantsuite-ppgc"
  local user status=0
  for user in postgres keycloak vernemq; do
    [ -f "${dir}/.env-${user}.secret" ] || continue
    set_env_value "${dir}/.env-${user}.secret" "password" "" || status=1
  done
  return "$status"
}

reset_redis_env_file() {
  local file="k8s/base/redis/.env.secret"
  [ -f "$file" ] || return 0
  set_env_value "$file" "password" ""
}

reset_rabbitmq_env_file() {
  local file="k8s/base/rabbitmq/plantsuite-rmq/.env.secret"
  [ -f "$file" ] || return 0
  set_env_value "$file" "password" ""
}

reset_keycloak_env_file() {
  local file="k8s/base/keycloak/plantsuite-kc/.env.secret"
  [ -f "$file" ] || return 0
  local status=0
  set_env_value "$file" "db_password" "" || status=1
  set_env_value "$file" "client-secret_ps-auth-introspection" "" || status=1
  set_env_value "$file" "client-secret_ps-tenants-admin" "" || status=1
  return "$status"
}

reset_vernemq_env_file() {
  local file="k8s/base/vernemq/.env.secret"
  [ -f "$file" ] || return 0
  set_env_value "$file" "DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__PASSWORD" ""
}

reset_plantsuite_env_file() {
  local file="k8s/base/plantsuite/.env.secret"
  [ -f "$file" ] || return 0
  local conn status=0
  printf -v conn "$_MONGO_CONN_FMT" ""; set_env_value "$file" "Database__MongoDb__ConnectionString" "$conn" || status=1
  printf -v conn "$_REDIS_CONN_FMT" ""; set_env_value "$file" "Database__Redis__ConnectionString" "$conn" || status=1
  printf -v conn "$_PG_CONN_FMT" ""; set_env_value "$file" "Database__Postgresql__ConnectionString" "$conn" || status=1
  printf -v conn "$_RMQ_CONN_FMT" ""; set_env_value "$file" "MessageBus__RabbitMQ__ConnectionString" "$conn" || status=1
  set_env_value "$file" "MessageBus__RabbitMQ__User" "" || status=1
  set_env_value "$file" "MessageBus__RabbitMQ__Password" "" || status=1
  set_env_value "$file" "MessageBus__MQTT__Password" "" || status=1
  set_env_value "$file" "Keycloak__AdminClientSecret" "" || status=1
  set_env_value "$file" "Keycloak__IntrospectionClientSecret" "" || status=1
  set_env_value "$file" "SMTP__Password" "" || status=1
  return "$status"
}

reset_gateway_env_file() {
  local file="k8s/base/plantsuite/gateway/appsettings.env"
  [ -f "$file" ] || return 0
  set_env_value "$file" "LocalAuth__Password" ""
}

reset_managed_secrets_files() {
  local status=0
  reset_mongodb_env_file || status=1
  reset_postgres_env_files || status=1
  reset_redis_env_file || status=1
  reset_rabbitmq_env_file || status=1
  reset_keycloak_env_file || status=1
  reset_vernemq_env_file || status=1
  reset_plantsuite_env_file || status=1
  reset_gateway_env_file || status=1
  klog "Secrets locais restaurados aos placeholders versionados."
  return "$status"
}

# TODO TEMPORÁRIO (MES): Extrai o tenantId do certificado de licença.
# Os serviços MES antigos (controlstations, wd, production) não concatenam
# tenantId ao usuário MQTT no código. Esse workaround permite ao instalador
# injetar a env var correta em formato "{tenantId}:system" diretamente no Kubernetes.
# NOTA: Aplica o patch via kubectl set env após o deploy - nenhum arquivo YAML é alterado.
# REMOVER quando os serviços migrarem para o padrão novo.
extract_tenant_id_from_license() {
  local license_file="k8s/base/plantsuite/license.crt"
  if [ ! -f "$license_file" ]; then
    error "Arquivo de licença não encontrado: $license_file"
    return 1
  fi

  local tenant_id
  tenant_id=$(
    sed -n '1,/-----END CERTIFICATE-----/p' "$license_file" \
      | openssl x509 -subject -noout -nameopt RFC2253 2>/dev/null \
      | sed -n 's/.*O[[:space:]]*=[[:space:]]*\([^,]*\).*/\1/p' \
      | tr -d '[:space:]'
  )

  if [ -z "$tenant_id" ]; then
    error "Não foi possível extrair tenantId do certificado de licença."
    return 1
  fi

  echo "$tenant_id"
}

# TODO TEMPORÁRIO (MES): Injeta a env var MQTT.User diretamente no Kubernetes via
# kubectl set env. Isso é necessário porque os serviços MES antigos não concatenam
# tenantId ao usuário MQTT no código e o Configuration do .NET carrega env vars
# após o appsettings.json, então o secret plantsuite-env (com User=system) sobrescreve.
# O patch é feito em 3 etapas: scale-to-0 → kubectl set env → scale-back.
# Isso evita que 2 pods subam em paralelo durante o rollout (用户体验更好).
# NOTA: wd tem container sidecar UI - usamos -c para targetar só o principal.
# REMOVER quando os serviços migrarem para o padrão novo.
patch_mes_mqtt_user_env() {
  local svc="$1"

  case "$svc" in
    controlstations|wd|production) ;;
    *) return 0 ;;
  esac

  local container env_var
  case "$svc" in
    controlstations) container="controlstations"; env_var="MessageBus__MQTT__User" ;;
    wd)              container="wd";              env_var="MessageBus__MQTT__User" ;;
    production)      container="production";      env_var="MessageBus__MQTT__User" ;;
  esac

  local tenant_id
  tenant_id=$(extract_tenant_id_from_license) || return $?

  local mqtt_user="${tenant_id}:system"

  local current_replicas
  current_replicas=$(kubectl get deployment "${svc}" -n plantsuite -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [ -z "$current_replicas" ] || [ "$current_replicas" -eq 0 ]; then
    current_replicas=1
  fi

  klog "Escalando $svc para 0 antes do patch de env var..."
  kubectl scale deployment "${svc}" -n plantsuite --replicas=0 2>&1
  if [ $? -ne 0 ]; then
    error "Falha ao escalar $svc para 0"
    return 1
  fi

  klog "Aguardando pods de $svc terminarem..."
  local max_wait=120
  local waited=0
  while [ "$waited" -lt "$max_wait" ]; do
    local ready
    ready=$(kubectl get deployment "${svc}" -n plantsuite -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$ready" = "0" ] || [ -z "$ready" ]; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  klog "Aplicando patch MQTT.User para $svc: $mqtt_user"
  kubectl set env "deployment/${svc}" -n plantsuite "-c" "$container" "${env_var}=${mqtt_user}" 2>&1
  if [ $? -ne 0 ]; then
    error "Falha ao injetar MQTT.User para $svc"
    return 1
  fi

  klog "Restaurando $svc para $current_replicas réplicas..."
  kubectl scale deployment "${svc}" -n plantsuite --replicas="$current_replicas" 2>&1
  if [ $? -ne 0 ]; then
    error "Falha ao restaurar réplicas de $svc"
    return 1
  fi

  klog "MQTT.User injetado via kubectl para $svc: $mqtt_user"
  return 0
}
