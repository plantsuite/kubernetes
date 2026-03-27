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

  [ -f "$file" ] || touch "$file"
  awk -v key="$key" -v value="$value" \
    'BEGIN{updated=0} $0 ~ ("^"key"=") {print key"="value; updated=1; next} {print} END{if(updated==0){print key"="value}}' \
    "$file" > "$file.tmp" && mv "$file.tmp" "$file"
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
      exit 1
    fi
  fi

  cat > "$env_file" <<EOF
$key=$password
EOF

  klog "Senha gerada e atualizada em $env_file"
}

# Função para atualizar .env.secret do keycloak com credenciais do PostgreSQL e client secrets
update_keycloak_secrets() {
  local secret_name="plantsuite-ppgc-pguser-keycloak"
  local namespace="postgresql"
  local env_file="k8s/base/keycloak/plantsuite-kc/.env.secret"

  local existing_db_username="" existing_db_password="" existing_auth_secret="" existing_tenants_secret=""
  if [ -f "$env_file" ]; then
    existing_db_username=$(grep "^db_username=" "$env_file" 2>/dev/null | cut -d'=' -f2)
    existing_db_password=$(grep "^db_password=" "$env_file" 2>/dev/null | cut -d'=' -f2)
    existing_auth_secret=$(grep "^client-secret_ps-auth-introspection=" "$env_file" 2>/dev/null | cut -d'=' -f2)
    existing_tenants_secret=$(grep "^client-secret_ps-tenants-admin=" "$env_file" 2>/dev/null | cut -d'=' -f2)
  fi

  if [ "$UPDATE_MODE" = true ] && [ -n "$existing_db_username" ] && [ -n "$existing_db_password" ] && [ -n "$existing_auth_secret" ] && [ -n "$existing_tenants_secret" ]; then
    klog "Modo update: preservando secrets existentes do Keycloak"
    return 0
  fi

  klog "Obtendo credenciais do banco de dados para o Keycloak..."

  local db_username="$existing_db_username"
  local db_password="$existing_db_password"
  if [ -z "$db_username" ] || [ -z "$db_password" ]; then
    db_username=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.user}' 2>/dev/null | base64 -d)
    db_password=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

    if [ -z "$db_username" ] || [ -z "$db_password" ]; then
      error "Não foi possível obter as credenciais do secret $secret_name no namespace $namespace."
      exit 1
    fi
  fi

  local auth_introspection_secret="$existing_auth_secret"
  local tenants_admin_secret="$existing_tenants_secret"

  if [ -z "$auth_introspection_secret" ]; then
    auth_introspection_secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  fi
  if [ -z "$tenants_admin_secret" ]; then
    tenants_admin_secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  fi

  cat > "$env_file" <<EOF
db_username=$db_username
db_password=$db_password
client-secret_ps-auth-introspection=$auth_introspection_secret
client-secret_ps-tenants-admin=$tenants_admin_secret
EOF

  klog "Credenciais do banco de dados atualizadas em $env_file"
}

# Função para obter as senhas do Redis e PostgreSQL e atualizar o .env.secret do VerneMQ
update_vernemq_secrets() {
  local env_file="k8s/base/vernemq/.env.secret"

  local existing_redis_password="" existing_postgres_password=""
  if [ -f "$env_file" ]; then
    existing_redis_password=$(grep "^DOCKER_VERNEMQ_VMQ_DIVERSITY__REDIS__PASSWORD=" "$env_file" 2>/dev/null | cut -d'=' -f2-)
    existing_postgres_password=$(grep "^DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__PASSWORD=" "$env_file" 2>/dev/null | cut -d'=' -f2-)
  fi

  if [ "$UPDATE_MODE" = true ] && [ -n "$existing_redis_password" ] && [ -n "$existing_postgres_password" ]; then
    klog "Modo update: preservando secrets existentes do VerneMQ"
    return 0
  fi

  klog "Obtendo senha do Redis para o VerneMQ..."

  local redis_password="$existing_redis_password"
  if [ -z "$redis_password" ]; then
    redis_password=$(kubectl get secret plantsuite-redis-env -n redis -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

    if [ -z "$redis_password" ] && [ -f "k8s/base/redis/.env.secret" ]; then
      redis_password=$(grep -E '^password=' k8s/base/redis/.env.secret | head -n1 | cut -d'=' -f2-)
    fi

    if [ -z "$redis_password" ]; then
      klog "Senha do Redis não encontrada, gerando uma nova..."
      local password
      password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
      if [ -z "$password" ]; then
        error "Não foi possível gerar senha para o Redis."
        exit 1
      fi
      echo "password=$password" > "k8s/base/redis/.env.secret"
      redis_password="$password"
      klog "Nova senha do Redis gerada e salva."
    fi
  fi

  klog "Obtendo senha do PostgreSQL para o VerneMQ..."

  local postgres_password="$existing_postgres_password"
  if [ -z "$postgres_password" ]; then
    local secret_name="plantsuite-ppgc-pguser-vernemq"
    local namespace="postgresql"
    postgres_password=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

    if [ -z "$postgres_password" ]; then
      error "Não foi possível obter a senha do PostgreSQL do secret $secret_name no namespace $namespace."
      exit 1
    fi
  fi

  if [ ! -f "$env_file" ]; then
    error "Arquivo $env_file não encontrado."
    exit 1
  fi

  if ! grep -q "^DOCKER_VERNEMQ_VMQ_DIVERSITY__REDIS__PASSWORD=" "$env_file"; then
    echo "DOCKER_VERNEMQ_VMQ_DIVERSITY__REDIS__PASSWORD=${redis_password}" >> "$env_file"
  else
    sed_inplace "s|^DOCKER_VERNEMQ_VMQ_DIVERSITY__REDIS__PASSWORD=.*|DOCKER_VERNEMQ_VMQ_DIVERSITY__REDIS__PASSWORD=${redis_password}|" "$env_file"
  fi

  sed_inplace "s|^DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__PASSWORD=.*|DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__PASSWORD=${postgres_password}|" "$env_file"

  klog "Senhas do Redis e PostgreSQL atualizadas no VerneMQ com sucesso."
}

# Função para atualizar k8s/base/plantsuite/.env.secret com segredos de MongoDB, RabbitMQ, Keycloak e gerar senha MQTT
update_plantsuite_env() {
  local env_file="k8s/base/plantsuite/.env.secret"

  klog "Atualizando .env.secret do Plantsuite com segredos do cluster..."

  local mongo_user mongo_pass
  mongo_user=$(kubectl get secret plantsuite-psmdb-secrets -n mongodb -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_USER}' 2>/dev/null | base64 -d)
  mongo_pass=$(kubectl get secret plantsuite-psmdb-secrets -n mongodb -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
  if [ -z "$mongo_user" ] || [ -z "$mongo_pass" ]; then
    error "Não foi possível obter credenciais do MongoDB em mongodb/plantsuite-psmdb-secrets."
    exit 1
  fi

  local mongo_conn existing_mongo_conn
  existing_mongo_conn=$(grep "^Database__MongoDb__ConnectionString=" "$env_file" 2>/dev/null | cut -d'=' -f2-)

  if [ -n "$existing_mongo_conn" ]; then
    if echo "$existing_mongo_conn" | grep -q "mongodb://"; then
      if echo "$existing_mongo_conn" | grep -q "@"; then
        mongo_conn=$(echo "$existing_mongo_conn" | sed "s|mongodb://[^@]*@|mongodb://${mongo_user}:${mongo_pass}@|")
      else
        mongo_conn=$(echo "$existing_mongo_conn" | sed "s|mongodb://|mongodb://${mongo_user}:${mongo_pass}@|")
      fi
    else
      mongo_conn="mongodb://${mongo_user}:${mongo_pass}@plantsuite-psmdb-rs0.mongodb.svc.cluster.local:27017/?authSource=admin&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=true&w=majority"
    fi
  else
    mongo_conn="mongodb://${mongo_user}:${mongo_pass}@plantsuite-psmdb-rs0.mongodb.svc.cluster.local:27017/?authSource=admin&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=true&w=majority"
  fi
  set_env_value "$env_file" "Database__MongoDb__ConnectionString" "$mongo_conn"

  local redis_pass
  redis_pass=$(kubectl get secret plantsuite-redis-env -n redis -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$redis_pass" ] && [ -f "k8s/base/redis/.env.secret" ]; then
    redis_pass=$(grep -E '^password=' k8s/base/redis/.env.secret | head -n1 | cut -d'=' -f2-)
  fi
  if [ -z "$redis_pass" ]; then
    error "Não foi possível obter a senha do Redis para montar a connection string do Redis."
    exit 1
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
    redis_conn="plantsuite-redis.redis.svc.cluster.local,password=${redis_pass}"
  fi
  set_env_value "$env_file" "Database__Redis__ConnectionString" "$redis_conn"

  local rmq_user rmq_pass
  rmq_user=$(kubectl get secret plantsuite-rmq-default-user -n rabbitmq -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
  rmq_pass=$(kubectl get secret plantsuite-rmq-default-user -n rabbitmq -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$rmq_user" ] || [ -z "$rmq_pass" ]; then
    error "Não foi possível obter usuário/senha do RabbitMQ em rabbitmq/plantsuite-rmq-default-user."
    exit 1
  fi
  set_env_value "$env_file" "MessageBus__RabbitMQ__User" "$rmq_user"
  set_env_value "$env_file" "MessageBus__RabbitMQ__Password" "$rmq_pass"

  local mqtt_pass
  mqtt_pass=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  if [ -z "$mqtt_pass" ]; then
    error "Não foi possível gerar senha do MQTT."
    exit 1
  fi
  set_env_value "$env_file" "MessageBus__MQTT__Password" "$mqtt_pass"

  local kc_admin kc_intro
  kc_admin=$(kubectl get secret keycloak -n keycloak -o jsonpath='{.data.client-secret_ps-tenants-admin}' 2>/dev/null | base64 -d)
  kc_intro=$(kubectl get secret keycloak -n keycloak -o jsonpath='{.data.client-secret_ps-auth-introspection}' 2>/dev/null | base64 -d)
  if [ -z "$kc_admin" ] || [ -z "$kc_intro" ]; then
    error "Não foi possível obter client secrets do Keycloak em keycloak/keycloak."
    exit 1
  fi
  set_env_value "$env_file" "Keycloak__AdminClientSecret" "$kc_admin"
  set_env_value "$env_file" "Keycloak__IntrospectionClientSecret" "$kc_intro"

  klog "Arquivo atualizado: $env_file"
}

# Função para limpar senhas dos arquivos .env.secret
cleanup_env_secrets() {
  klog "Iniciando limpeza de senhas dos arquivos .env.secret..."

  local files=(
    "k8s/base/keycloak/plantsuite-kc/.env.secret"
    "k8s/base/plantsuite/.env.secret"
    "k8s/base/redis/.env.secret"
    "k8s/base/vernemq/.env.secret"
  )

  for file in "${files[@]}"; do
    if [ ! -f "$file" ]; then
      warning "Arquivo $file não encontrado. Pulando..."
      continue
    fi

    klog "Processando $file..."

    tmpfile=$(mktemp)
    perl -0777 -pe '
      s/^```[^\n]*\n|```[ \t]*\n//mg;
      s/^(Database__MongoDb__ConnectionString=)(.*?mongodb:\/\/[^:]+:)[^@]*@/$1$2@/mix;
      s/^(Database__Redis__ConnectionString=.*?,)password=[^,\r\n]*/$1password=/mi;
      s/^(.*(?i:password).*?)=.*/$1=/mg;
      s/^(client-secret_[^=\n]*)=.*/$1=/mig;
      s/^(Keycloak__AdminClientSecret)=.*/$1=/mg;
      s/^(Keycloak__IntrospectionClientSecret)=.*/$1=/mg;
    ' "$file" > "$tmpfile" && mv "$tmpfile" "$file"

    klog "Senhas removidas de $file."
  done

  klog "Limpeza de senhas concluída."
}
