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
  kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.${data_key}}" 2>/dev/null | base64 -d
}

# Atualiza arquivos dependentes quando a senha do Redis mudar.
sync_redis_password_dependents() {
  local redis_password="$1"
  [ -z "$redis_password" ] && return 0

  # VerneMQ depende diretamente da senha do Redis
  local vernemq_env="k8s/base/vernemq/.env.secret"
  if [ -f "$vernemq_env" ]; then
    set_env_value "$vernemq_env" "DOCKER_VERNEMQ_VMQ_DIVERSITY__REDIS__PASSWORD" "$redis_password"
  fi

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

  cat > "$env_file" <<EOF
$key=$password
EOF

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

  # Mantém PlantSuite alinhado aos client secrets mais recentes do Keycloak.
  sync_keycloak_client_secrets_dependents "$tenants_admin_secret" "$auth_introspection_secret"

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
    # Preferência: .env.secret local (fonte mais atual durante instalação) -> Secret no cluster.
    redis_password=$(get_env_value "k8s/base/redis/.env.secret" "password")
    if [ -z "$redis_password" ]; then
      redis_password=$(get_k8s_secret_value "redis" "plantsuite-redis-env" "password")
    fi

    if [ -z "$redis_password" ]; then
      klog "Senha do Redis não encontrada, gerando uma nova..."
      local password
      password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
      if [ -z "$password" ]; then
        error "Não foi possível gerar senha para o Redis."
        return 1
      fi
      echo "password=$password" > "k8s/base/redis/.env.secret"
      redis_password="$password"
      sync_redis_password_dependents "$redis_password"
      klog "Nova senha do Redis gerada e salva."
    fi
  fi

  klog "Obtendo senha do PostgreSQL para o VerneMQ..."

  # Fonte da verdade: Secret gerado pelo PostgreSQL Operator.
  local secret_name="plantsuite-ppgc-pguser-vernemq"
  local namespace="postgresql"
  local postgres_password
  postgres_password=$(get_k8s_secret_value "$namespace" "$secret_name" "password")

  if [ -z "$postgres_password" ]; then
    if [ "$UPDATE_MODE" = true ] && [ -n "$existing_postgres_password" ]; then
      warning "Secret $namespace/$secret_name indisponível; preservando senha local do VerneMQ em modo update."
      postgres_password="$existing_postgres_password"
    else
      error "Não foi possível obter a senha do PostgreSQL do secret $secret_name no namespace $namespace."
      return 1
    fi
  fi

  if [ ! -f "$env_file" ]; then
    error "Arquivo $env_file não encontrado."
    return 1
  fi

  # Usa helper de .env para evitar problemas de escaping com sed em senhas contendo
  # caracteres especiais (/, &, |, etc.).
  set_env_value "$env_file" "DOCKER_VERNEMQ_VMQ_DIVERSITY__REDIS__PASSWORD" "$redis_password"
  set_env_value "$env_file" "DOCKER_VERNEMQ_VMQ_DIVERSITY__POSTGRES__PASSWORD" "$postgres_password"

  klog "Senhas do Redis e PostgreSQL atualizadas no VerneMQ com sucesso."
}

# Função para atualizar k8s/base/plantsuite/.env.secret com segredos de MongoDB, RabbitMQ, Keycloak e gerar senha MQTT
update_plantsuite_env() {
  local env_file="k8s/base/plantsuite/.env.secret"

  klog "Atualizando .env.secret do Plantsuite com segredos do cluster..."

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
    redis_conn="plantsuite-redis.redis.svc.cluster.local,password=${redis_pass}"
  fi
  set_env_value "$env_file" "Database__Redis__ConnectionString" "$redis_conn"

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
  if [ -n "$existing_rmq_conn" ]; then
    if echo "$existing_rmq_conn" | grep -q "amqp://"; then
      if echo "$existing_rmq_conn" | grep -q "@"; then
        rmq_conn=$(echo "$existing_rmq_conn" | sed "s|amqp://[^@]*@|amqp://${rmq_user}:${rmq_pass}@|")
      else
        rmq_conn=$(echo "$existing_rmq_conn" | sed "s|amqp://|amqp://${rmq_user}:${rmq_pass}@|")
      fi
    else
      rmq_conn="amqp://${rmq_user}:${rmq_pass}@plantsuite-rmq.rabbitmq.svc.cluster.local:5672/"
    fi
  else
    rmq_conn="amqp://${rmq_user}:${rmq_pass}@plantsuite-rmq.rabbitmq.svc.cluster.local:5672/"
  fi

  set_env_value "$env_file" "MessageBus__RabbitMQ__ConnectionString" "$rmq_conn"
  set_env_value "$env_file" "MessageBus__RabbitMQ__User" "$rmq_user"
  set_env_value "$env_file" "MessageBus__RabbitMQ__Password" "$rmq_pass"

  local mqtt_pass
  mqtt_pass=$(get_env_value "$env_file" "MessageBus__MQTT__Password")
  if [ -z "$mqtt_pass" ]; then
    mqtt_pass=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  fi
  if [ -z "$mqtt_pass" ]; then
    error "Não foi possível gerar senha do MQTT."
    return 1
  fi
  set_env_value "$env_file" "MessageBus__MQTT__Password" "$mqtt_pass"

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
