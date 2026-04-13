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
  export _AWK_KEY="$key" _AWK_VALUE="$value"
  awk \
    'BEGIN{updated=0; key=ENVIRON["_AWK_KEY"]; value=ENVIRON["_AWK_VALUE"]}
     $0 ~ ("^"key"=") {print key"="value; updated=1; next}
     {print}
     END{if(updated==0){print key"="value}}' \
    "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  unset _AWK_KEY _AWK_VALUE
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

  local pg_pass
  local existing_pg_conn
  existing_pg_conn=$(grep "^Database__Postgresql__ConnectionString=" "$env_file" 2>/dev/null | cut -d'=' -f2-)
  pg_pass=$(get_k8s_secret_value "postgresql" "plantsuite-ppgc-pguser-vernemq" "password")
  if [ -z "$pg_pass" ]; then
    if [ "$UPDATE_MODE" = true ] && [ -n "$existing_pg_conn" ] && echo "$existing_pg_conn" | grep -q "Password="; then
      warning "postgresql/plantsuite-ppgc-pguser-vernemq indisponível; preservando senha local do PostgreSQL em modo update."
      pg_pass=$(echo "$existing_pg_conn" | sed -n 's|.*Password=\([^;]*\).*|\1|p')
    fi
  fi
  if [ -z "$pg_pass" ]; then
    error "Não foi possível obter a senha do PostgreSQL em postgresql/plantsuite-ppgc-pguser-vernemq."
    return 1
  fi

  local pg_conn
  if [ -n "$existing_pg_conn" ]; then
    if echo "$existing_pg_conn" | grep -q "Password="; then
      pg_conn=$(echo "$existing_pg_conn" | sed "s|Password=[^;]*|Password=${pg_pass}|")
    else
      pg_conn="${existing_pg_conn};Password=${pg_pass}"
    fi
  else
    pg_conn="Host=plantsuite-ppgc-pgbouncer.postgresql.svc.cluster.local;Port=5432;Database=vernemq;Username=vernemq;Password=${pg_pass};Minimum Pool Size=10;Maximum Pool Size=10"
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

# TODO TEMPORÁRIO (MES): Extrai o tenantId do certificado de licença.
# Os serviços MES antigos (controlstations, gateway, wd, production) não concatenam
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
      | openssl x509 -subject -noout 2>/dev/null \
      | sed -n 's/.*O=\([^,]*\),.*/\1/p'
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
# NOTA: gateway e wd têm container sidecar UI - usamos -c para targetar só o principal.
# REMOVER quando os serviços migrarem para o padrão novo.
patch_mes_mqtt_user_env() {
  local svc="$1"

  case "$svc" in
    controlstations|gateway|wd|production) ;;
    *) return 0 ;;
  esac

  local container env_var
  case "$svc" in
    controlstations) container="controlstations"; env_var="MessageBus__MQTT__User" ;;
    gateway)         container="gateway";         env_var="MessageBus__MQTT__User" ;;
    wd)              container="wd";              env_var="MQTT__User" ;;
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