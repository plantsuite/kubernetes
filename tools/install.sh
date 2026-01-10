# Função para aguardar o webhook do cert-manager ficar pronto (usando apenas kubectl)
wait_cert_manager_webhook_ready() {
  local namespace="cert-manager"
  local service="cert-manager-webhook"
  local timeout=60
  local elapsed=0
  local interval=2
  local spinner=("|" "/" "-" "\\")
  
  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      endpoints=$(kubectl get endpoints "$service" -n "$namespace" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
      if [ -n "$endpoints" ]; then
        printf "\r\033[K"
        klog "cert-manager webhook está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\rAguardando cert-manager webhook... %s" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done
    
    printf "\r\033[K"
    handle_timeout "cert-manager webhook"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}
#!/bin/bash
# install.sh - Script de instalação automatizada dos componentes Kubernetes
#
# Este script automatiza a instalação dos componentes na ordem correta,
# aguarda serviços ficarem disponíveis, obtém secrets necessários e ajusta dependências.
# Também serve como guia de instalação, com comentários e logs detalhados.

# Variável global para armazenar o overlay selecionado
SELECTED_OVERLAY=""

# Função para exibir erros
error() {
  printf "\033[1;31m[ERRO]\033[0m %s\n" "$1" >&2
}

# Função para exibir avisos
warning() {
  printf "\033[1;33m[AVISO]\033[0m %s\n" "$1"
}

# Função para exibir logs formatados
klog() {
  printf "\033[1;34m[INFO]\033[0m %s\n" "$1"
}

# Verifica se o script está sendo executado a partir da raiz do repositório
assert_repo_root() {
  if [ ! -d "apps" ] || [ ! -d "apps/base" ] || [ ! -f "README.md" ]; then
    error "Este script deve ser executado a partir da raiz do repositório."
    echo "Pastas/arquivos esperados não encontrados: 'apps/', 'apps/base/', 'README.md'." >&2
    echo "Exemplo de uso: ./tools/install.sh" >&2
    exit 1
  fi
}

# Garante execução na raiz do repo
assert_repo_root

# Aguarda um intervalo fixo exibindo spinner sem prefixo e limpa a linha ao concluir
wait_with_spinner() {
  local seconds="$1"
  local message="$2"
  local elapsed=0
  local interval=1
  local spinner=("|" "/" "-" "\\")

  while [ $elapsed -lt $seconds ]; do
    idx=$(( (elapsed / interval) % 4 ))
    remaining=$((seconds - elapsed))
    printf "\r%s (restam %ss) %s" "$message" "$remaining" "${spinner[$idx]}"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  printf "\r\033[K"
}

# Função para atualizar .env.secret do keycloak com credenciais do PostgreSQL e client secrets
update_keycloak_secrets() {
  local secret_name="plantsuite-ppgc-pguser-keycloak"
  local namespace="postgresql"
  local env_file="apps/base/keycloak/plantsuite-kc/.env.secret"
  
  # Em modo UPDATE, preserva secrets existentes
  if [ "$UPDATE_MODE" = true ] && [ -f "$env_file" ]; then
    klog "Modo update: preservando secrets existentes do Keycloak"
    return 0
  fi
  
  klog "Obtendo credenciais do banco de dados para o Keycloak..."
  
  # Obtém username e password do secret
  local db_username=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.user}' 2>/dev/null | base64 -d)
  local db_password=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  
  if [ -z "$db_username" ] || [ -z "$db_password" ]; then
    error "Não foi possível obter as credenciais do secret $secret_name no namespace $namespace."
    exit 1
  fi
  
  # Lê valores existentes dos client secrets (se existirem)
  local auth_introspection_secret=""
  local tenants_admin_secret=""
  if [ -f "$env_file" ]; then
    auth_introspection_secret=$(grep "^client-secret_ps-auth-introspection=" "$env_file" 2>/dev/null | cut -d'=' -f2)
    tenants_admin_secret=$(grep "^client-secret_ps-tenants-admin=" "$env_file" 2>/dev/null | cut -d'=' -f2)
  fi
  
  # Gera client secrets se não existirem
  if [ -z "$auth_introspection_secret" ]; then
    auth_introspection_secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  fi
  if [ -z "$tenants_admin_secret" ]; then
    tenants_admin_secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  fi
  
  # Atualiza o arquivo .env.secret
  cat > "$env_file" <<EOF
db_username=$db_username
db_password=$db_password
client-secret_ps-auth-introspection=$auth_introspection_secret
client-secret_ps-tenants-admin=$tenants_admin_secret
EOF
  
  klog "Credenciais do banco de dados atualizadas em $env_file"
}

# Função para obter a senha do Valkey e atualizar o .env.secret do VerneMQ
update_vernemq_valkey_password() {
  local env_file="apps/base/vernemq/.env.secret"
  
  klog "Obtendo senha do Valkey para o VerneMQ..."
  
  # Obter senha do Valkey
  local valkey_password
  # Primeiro tenta obter do Secret no cluster (nome gerado pelo kustomize: plantsuite-valkey-password)
  valkey_password=$(kubectl get secret plantsuite-valkey-password -n valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  
  # Se não encontrar no cluster, tenta obter do arquivo local .env.secret usado para gerar o Secret
  if [ -z "$valkey_password" ] && [ -f "apps/base/valkey/.env.secret" ]; then
    valkey_password=$(grep -E '^password=' apps/base/valkey/.env.secret | head -n1 | cut -d'=' -f2-)
  fi
  
  if [ -z "$valkey_password" ]; then
    error "Não foi possível obter a senha do Valkey."
    exit 1
  fi
  
  # Atualizar .env.secret do VerneMQ
  if [ ! -f "$env_file" ]; then
    error "Arquivo $env_file não encontrado."
    exit 1
  fi
  
  # Usar sed para atualizar a senha do Redis (Valkey)
  sed -i '' "s|^DOCKER_VERNEMQ_VMQ_DIVERSITY__REDIS__PASSWORD=.*|DOCKER_VERNEMQ_VMQ_DIVERSITY__REDIS__PASSWORD=${valkey_password}|" "$env_file"
  
  klog "Senha do Valkey atualizada no VerneMQ com sucesso."
}

# Função para gerar senha segura e atualizar .env.secret
generate_secure_password() {
  local env_file="$1"
  local key="$2"
  local length="${3:-32}"  # Tamanho padrão de 32 caracteres
  
  # Em modo UPDATE, preserva senha existente
  if [ "$UPDATE_MODE" = true ] && [ -f "$env_file" ]; then
    klog "Modo update: preservando senha existente em $env_file"
    return 0
  fi
  
  klog "Gerando senha segura..."
  
  # Gera senha usando caracteres alfanuméricos (compatível com Redis/Valkey e maioria dos sistemas)
  # Evita caracteres especiais que podem causar problemas de escape
  local password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length")
  
  if [ -z "$password" ]; then
    error "Não foi possível gerar senha."
    exit 1
  fi
  
  # Atualiza o arquivo .env.secret
  cat > "$env_file" <<EOF
$key=$password
EOF
  
  klog "Senha gerada e atualizada em $env_file"
}

# Atualiza chave em um arquivo .env (cria se não existir)
set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  
  [ -f "$file" ] || touch "$file"
  awk -v key="$key" -v value="$value" 'BEGIN{updated=0} $0 ~ ("^"key"=") {print key"="value; updated=1; next} {print} END{if(updated==0){print key"="value}}' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Função para atualizar apps/base/plantsuite/.env.secret com segredos de MongoDB, RabbitMQ, Keycloak e gerar senha MQTT
update_plantsuite_env() {
  local env_file="apps/base/plantsuite/.env.secret"

  klog "Atualizando .env.secret do Plantsuite com segredos do cluster..."

  # MongoDB admin user/pass
  local mongo_user mongo_pass
  mongo_user=$(kubectl get secret plantsuite-psmdb-secrets -n mongodb -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_USER}' 2>/dev/null | base64 -d)
  mongo_pass=$(kubectl get secret plantsuite-psmdb-secrets -n mongodb -o jsonpath='{.data.MONGODB_DATABASE_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
  if [ -z "$mongo_user" ] || [ -z "$mongo_pass" ]; then
    error "Não foi possível obter credenciais do MongoDB em mongodb/plantsuite-psmdb-secrets."
    exit 1
  fi
  
  # Verifica se já existe uma connection string; se sim, atualiza apenas credenciais
  local mongo_conn
  local existing_mongo_conn
  existing_mongo_conn=$(grep "^Database__MongoDb__ConnectionString=" "$env_file" 2>/dev/null | cut -d'=' -f2-)
  
  if [ -n "$existing_mongo_conn" ]; then
    # Preserva a connection string existente
    # Se tiver user:pass (format: mongodb://user:pass@...), atualiza apenas credenciais
    # Se não tiver autenticação, adiciona no formato mongodb://user:pass@host...
    if echo "$existing_mongo_conn" | grep -q "mongodb://"; then
      if echo "$existing_mongo_conn" | grep -q "@"; then
        # Tem autenticação: atualiza user:pass
        mongo_conn=$(echo "$existing_mongo_conn" | sed "s|mongodb://[^@]*@|mongodb://${mongo_user}:${mongo_pass}@|")
      else
        # Não tem autenticação: insere após mongodb://
        mongo_conn=$(echo "$existing_mongo_conn" | sed "s|mongodb://|mongodb://${mongo_user}:${mongo_pass}@|")
      fi
    else
      # Formato inesperado, cria do zero
      mongo_conn="mongodb://${mongo_user}:${mongo_pass}@plantsuite-psmdb-rs0.mongodb.svc.cluster.local:27017/?authSource=admin&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=true&w=majority"
    fi
  else
    # Cria connection string do zero
    mongo_conn="mongodb://${mongo_user}:${mongo_pass}@plantsuite-psmdb-rs0.mongodb.svc.cluster.local:27017/?authSource=admin&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=true&w=majority"
  fi
  set_env_value "$env_file" "Database__MongoDb__ConnectionString" "$mongo_conn"

  # Redis/Valkey connection string
  local valkey_pass
  valkey_pass=$(kubectl get secret plantsuite-valkey-password -n valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$valkey_pass" ] && [ -f "apps/base/valkey/.env.secret" ]; then
    valkey_pass=$(grep -E '^password=' apps/base/valkey/.env.secret | head -n1 | cut -d'=' -f2-)
  fi
  if [ -z "$valkey_pass" ]; then
    error "Não foi possível obter a senha do Valkey para montar a connection string do Redis."
    exit 1
  fi
  
  # Verifica se já existe uma connection string; se sim, atualiza apenas password
  local redis_conn
  local existing_redis_conn
  existing_redis_conn=$(grep "^Database__Redis__ConnectionString=" "$env_file" 2>/dev/null | cut -d'=' -f2-)
  
  if [ -n "$existing_redis_conn" ]; then
    # Preserva a connection string existente
    # Se tem "password=", atualiza o valor
    # Se não tem, adiciona ", password="
    if echo "$existing_redis_conn" | grep -q "password="; then
      # Tem password: atualiza valor (pode ser vazio ou com valor anterior)
      redis_conn=$(echo "$existing_redis_conn" | sed "s|password=[^,]*|password=${valkey_pass}|")
    else
      # Não tem password: adiciona ao final
      redis_conn="${existing_redis_conn},password=${valkey_pass}"
    fi
  else
    # Cria connection string do zero
    redis_conn="plantsuite-valkey.valkey.svc.cluster.local,password=${valkey_pass}"
  fi
  set_env_value "$env_file" "Database__Redis__ConnectionString" "$redis_conn"

  # RabbitMQ default user
  local rmq_user rmq_pass
  rmq_user=$(kubectl get secret plantsuite-rmq-default-user -n rabbitmq -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
  rmq_pass=$(kubectl get secret plantsuite-rmq-default-user -n rabbitmq -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  if [ -z "$rmq_user" ] || [ -z "$rmq_pass" ]; then
    error "Não foi possível obter usuário/senha do RabbitMQ em rabbitmq/plantsuite-rmq-default-user."
    exit 1
  fi
  set_env_value "$env_file" "MessageBus__RabbitMQ__User" "$rmq_user"
  set_env_value "$env_file" "MessageBus__RabbitMQ__Password" "$rmq_pass"

  # MQTT password (gerado)
  local mqtt_pass
  mqtt_pass=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  if [ -z "$mqtt_pass" ]; then
    error "Não foi possível gerar senha do MQTT."
    exit 1
  fi
  set_env_value "$env_file" "MessageBus__MQTT__Password" "$mqtt_pass"

  # Keycloak client secrets
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

# Função para obter o caminho correto do componente baseado no overlay
get_component_path() {
  local base_path="$1"
  
  # Se um overlay foi selecionado, verifica se existe o componente no overlay
  if [ -n "$SELECTED_OVERLAY" ] && [ "$SELECTED_OVERLAY" != "base" ]; then
    # Remove o prefixo "apps/base/" do caminho para obter o caminho relativo
    local relative_path="${base_path#apps/base/}"
    local overlay_path="apps/overlays/${SELECTED_OVERLAY}/${relative_path}"
    
    # Verifica se o diretório existe e contém um arquivo kustomization
    if [ -d "$overlay_path" ] && ( [ -f "${overlay_path}kustomization.yaml" ] || [ -f "${overlay_path}kustomization.yml" ] || [ -f "${overlay_path}Kustomization" ] ); then
      echo "$overlay_path"
      return 0
    fi
  fi
  
  # Se não encontrar no overlay, usa o caminho base
  echo "$base_path"
}

# Função para aplicar um componente kustomize (com suporte a helm charts)
apply_component() {
  local base_path="$1"
  local name="$2"
  local component_path=$(get_component_path "$base_path")
  local max_retries=3
  local retry_delay=30
  local attempt=1
  
  if [ "$component_path" != "$base_path" ]; then
    klog "Instalando $name (overlay: $SELECTED_OVERLAY) - $component_path"
  else
    klog "Instalando $name - $component_path"
  fi
  
  while true; do
    # Captura stderr para verificar tipo de erro
    error_output=$(kubectl kustomize --enable-helm "$component_path" 2>&1 | kubectl apply --server-side -f - 2>&1)
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
      klog "$name aplicado com sucesso."
      return 0
    else
      # Verifica se é um erro de configuração do kustomize (não deve tentar novamente)
      if echo "$error_output" | grep -q "error: accumulating resources:"; then
        error "Erro de configuração no kustomize para $name. Verifique o kustomization.yaml."
        echo "$error_output" >&2
        exit 1
      fi
      
      # Verifica se é um erro de validação de esquema (não deve tentar novamente)
      if echo "$error_output" | grep -q "error validating"; then
        error "Erro de validação de esquema para $name. Verifique os manifestos."
        echo "$error_output" >&2
        exit 1
      fi

      # Erros de objeto inválido (ex.: campos obrigatórios ausentes ou nulos) - não tentar novamente
      if echo "$error_output" | grep -qi " is invalid"; then
        error "Erro de configuração (objeto inválido) para $name. Corrija o manifesto antes de prosseguir."
        echo "$error_output" >&2
        exit 1
      fi
      
      # Erros transitórios (webhook, network, etc.) - pode tentar novamente
      if [ $attempt -lt $max_retries ]; then
        warning "Falha ao aplicar $name (tentativa $attempt de $max_retries)."
        echo "$error_output" >&2
        wait_with_spinner "$retry_delay" "Aguardando $retry_delay segundos antes de tentar novamente..."
        attempt=$((attempt + 1))
      else
        # Após 3 tentativas, pergunta ao usuário
        warning "Falha ao aplicar $name após $max_retries tentativas."
        echo "$error_output" >&2
        echo ""
        read -p "Deseja continuar tentando? (s/n): " continue_trying
        if [[ "$continue_trying" =~ ^[Ss]$ ]]; then
          klog "Reiniciando tentativas para $name..."
          attempt=1
        else
          error "Instalação de $name cancelada pelo usuário."
          exit 1
        fi
      fi
    fi
  done
}

# Função para aguardar StatefulSet com spinner e tratamento de timeout interativo
wait_statefulset_ready() {
  local namespace="$1"
  local label_selector="$2"
  local fallback_name="$3"
  local display_name="$4"
  local timeout=300
  local interval=3
  local elapsed=0
  local spinner=("|" "/" "-" "\\")
  local sts_name=""

  sts_name=$(kubectl get sts -n "$namespace" -l "$label_selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$sts_name" ]; then
    sts_name="$fallback_name"
  fi

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      desired=$(kubectl get sts "$sts_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
      ready=$(kubectl get sts "$sts_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" = "$ready" ] && [ "$ready" -gt 0 ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\rAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar PerconaServerMongoDB (CR) ficar pronto
wait_psmdb_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|" "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      state=$(kubectl get psmdb "$name" -n "$namespace" -o jsonpath='{.status.state}' 2>/dev/null)
      if [ "$state" = "ready" ] || [ "$state" = "clusterInitializing" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto (estado: $state)."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\rAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar PerconaPGCluster (CR) ficar pronto
wait_postgrescluster_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|" "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      state=$(kubectl get perconapgcluster "$name" -n "$namespace" -o jsonpath='{.status.state}' 2>/dev/null)
      if [ "$state" = "ready" ] || [ "$state" = "updating" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto (estado: $state)."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\rAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar Keycloak (CR) ficar pronto
wait_keycloak_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|", "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      status=$(kubectl get keycloak "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [ "$status" = "True" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\rAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar KeycloakRealmImport (CR) ficar pronto
wait_keycloak_realm_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|", "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      status=$(kubectl get keycloakrealmimport "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)
      if [ "$status" = "True" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\rAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar RabbitmqCluster (CR) ficar pronto
wait_rabbitmq_ready() {
  local namespace="$1"
  local name="$2"
  local display_name="$3"
  local timeout=300
  local interval=5
  local elapsed=0
  local spinner=("|", "/" "-" "\\")

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      status=$(kubectl get rabbitmqcluster "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="AllReplicasReady")].status}' 2>/dev/null)
      if [ "$status" = "True" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\rAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Checa rapidamente se um Deployment está pronto
is_deployment_ready() {
  local namespace="$1"
  local name="$2"

  local desired ready
  desired=$(kubectl get deploy "$name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  ready=$(kubectl get deploy "$name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)

  if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" = "$ready" ] && [ "$ready" -gt 0 ]; then
    return 0
  fi
  return 1
}

# Checa rapidamente se um StatefulSet está pronto
is_statefulset_ready() {
  local namespace="$1"
  local name="$2"

  local desired ready
  desired=$(kubectl get sts "$name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  ready=$(kubectl get sts "$name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)

  if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" = "$ready" ] && [ "$ready" -gt 0 ]; then
    return 0
  fi
  return 1
}

# Aguarda todos os Deployments/StatefulSets do Plantsuite em paralelo, reportando progresso
wait_plantsuite_components_ready() {
  local namespace="plantsuite"
  local timeout=900
  local interval=5
  local start_ts=$(date +%s)

  IFS=$'\n' read -r -d '' -a deployments <<< "$(kubectl get deploy -n \"$namespace\" -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}' 2>/dev/null; printf '\0')"
  IFS=$'\n' read -r -d '' -a statefulsets <<< "$(kubectl get sts -n \"$namespace\" -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}' 2>/dev/null; printf '\0')"

  local pending=()
  local item
  for item in "${deployments[@]}"; do
    [ -n "$item" ] && pending+=("deploy:${item}")
  done
  for item in "${statefulsets[@]}"; do
    [ -n "$item" ] && pending+=("sts:${item}")
  done

  if [ ${#pending[@]} -eq 0 ]; then
    klog "Componentes do PlantSuite estão prontos."
    return 0
  fi

  klog "Aguardando componentes do Plantsuite ficarem prontos..."

  while [ ${#pending[@]} -gt 0 ]; do
    local new_pending=()
    for item in "${pending[@]}"; do
      IFS=":" read -r kind name <<<"$item"
      if [ "$kind" = "deploy" ]; then
        if is_deployment_ready "$namespace" "$name"; then
          klog "$name está pronto."
          continue
        fi
      else
        if is_statefulset_ready "$namespace" "$name"; then
          klog "$name está pronto."
          continue
        fi
      fi
      new_pending+=("$item")
    done

    pending=("${new_pending[@]}")
    if [ ${#pending[@]} -eq 0 ]; then
      printf "\r\033[K"
      break
    fi

    local elapsed=$(( $(date +%s) - start_ts ))
    if [ $elapsed -ge $timeout ]; then
      printf "\r\033[K"
      handle_timeout "Plantsuite (pendentes: ${pending[*]})"
      # handle_timeout só retorna se o usuário decidir continuar/aguardar; reinicia contagem
      start_ts=$(date +%s)
    fi

    printf "\rAguardando componentes do Plantsuite: %s" "$(printf '%s ' "${pending[@]#*:}")"
    sleep $interval
  done
}

# Função para perguntar ao usuário como proceder quando um recurso não fica pronto
handle_timeout() {
  local resource_name="$1"
  while true; do
    echo ""
    echo "⚠️  $resource_name não ficou pronto dentro do tempo esperado."
    echo ""
    echo "O que deseja fazer?"
    echo "  1) Continuar com a execução (sem garantia de funcionamento)"
    echo "  2) Encerrar o script"
    echo "  3) Aguardar novamente ($timeout segundos)"
    echo ""
    read -p "Digite sua escolha (1/2/3): " choice
    
    case $choice in
      1)
        klog "$resource_name: continuando com a execução..."
        return 0
        ;;
      2)
        error "Instalação interrompida pelo usuário."
        exit 1
        ;;
      3)
        klog "$resource_name: aguardando novamente..."
        return 1
        ;;
      *)
        echo "Opção inválida. Tente novamente."
        ;;
    esac
  done
}

# Função para aguardar DaemonSet com spinner e tratamento de timeout interativo
wait_daemonset_ready() {
  local namespace="$1"
  local label_selector="$2"
  local fallback_name="$3"
  local display_name="$4"
  local timeout=120
  local interval=2
  local elapsed=0
  local spinner=("|" "/" "-" "\\")
  local daemonset_name=""

  # Tenta identificar o nome do daemonset
  daemonset_name=$(kubectl get ds -n "$namespace" -l "$label_selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$daemonset_name" ]; then
    daemonset_name="$fallback_name"
  fi

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      desired=$(kubectl get ds "$daemonset_name" -n "$namespace" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
      ready=$(kubectl get ds "$daemonset_name" -n "$namespace" -o jsonpath='{.status.numberReady}' 2>/dev/null)
      
      if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" -eq "$ready" ] && [ "$ready" -gt 0 ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\rAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}

# Função para aguardar deployment com spinner e tratamento de timeout interativo
wait_deployment_ready() {
  local namespace="$1"
  local label_selector="$2"
  local fallback_name="$3"
  local display_name="$4"
  local timeout=120
  local interval=2
  local elapsed=0
  local spinner=("|" "/" "-" "\\")
  local deploy_name=""

  # Tenta identificar o nome do deployment
  deploy_name=$(kubectl get deploy -n "$namespace" -l "$label_selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$deploy_name" ]; then
    deploy_name="$fallback_name"
  fi

  while true; do
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
      ready=$(kubectl get deploy "$deploy_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
      if [ "$ready" = "True" ]; then
        printf "\r\033[K"
        klog "$display_name está pronto."
        return 0
      fi
      idx=$(( (elapsed / interval) % 4 ))
      printf "\rAguardando %s ficar pronto... %s" "$display_name" "${spinner[$idx]}"
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    printf "\r\033[K"
    handle_timeout "$display_name"
    if [ $? -eq 0 ]; then
      return 0
    fi
  done
}


# Verifica se kubectl está instalado
if ! command -v kubectl &> /dev/null; then
  error "kubectl não encontrado. Instale o kubectl antes de continuar."
  exit 1
fi

klog "Obtendo contextos disponíveis do Kubernetes..."
kubectl config get-contexts

klog "Contexto atual: $(kubectl config current-context)"
echo ""
echo "Digite o nome do contexto Kubernetes a ser utilizado (pressione Enter para manter o atual):"
read -r KUBE_CONTEXT
if [ -n "$KUBE_CONTEXT" ]; then
  klog "Alterando para o contexto: $KUBE_CONTEXT"
  kubectl config use-context "$KUBE_CONTEXT"
else
  klog "Mantendo o contexto atual."
fi

# Seleção dinâmica de overlays
echo ""
klog "Selecione o overlay para instalação:"
overlays_dir="apps/overlays"
declare -a AVAILABLE_OVERLAYS
if [ -d "$overlays_dir" ]; then
  for d in "$overlays_dir"/*/; do
    [ -d "$d" ] || continue
    AVAILABLE_OVERLAYS+=("$(basename "$d")")
  done
fi

echo "  1) base (padrão)"
idx=2
for name in "${AVAILABLE_OVERLAYS[@]}"; do
  echo "  $idx) $name"
  idx=$((idx+1))
done
echo ""
read -p "Digite sua escolha (número, padrão: 1): " overlay_choice
if [ -z "$overlay_choice" ] || [ "$overlay_choice" = "1" ]; then
  SELECTED_OVERLAY="base"
else
  # Mapear escolha para o índice no array AVAILABLE_OVERLAYS
  chosen_index=$((overlay_choice - 2))
  if [ $chosen_index -ge 0 ] && [ $chosen_index -lt ${#AVAILABLE_OVERLAYS[@]} ]; then
    SELECTED_OVERLAY="${AVAILABLE_OVERLAYS[$chosen_index]}"
  else
    warning "Escolha inválida. Usando 'base'."
    SELECTED_OVERLAY="base"
  fi
fi

# Detectar instalação existente
UPDATE_MODE=false
INCOMPLETE_INSTALL=false

# Verifica TODOS os componentes essenciais
components_check=(
  "metrics-server:deployment:kube-system:k8s-app=metrics-server"
  "cert-manager:namespace:cert-manager:"
  "istio-system:namespace:istio-system:"
  "istio-ingress:namespace:istio-ingress:"
  "aspire:namespace:aspire:"
  "mongodb:namespace:mongodb:"
  "postgresql:namespace:postgresql:"
  "valkey:namespace:valkey:"
  "keycloak:namespace:keycloak:"
  "rabbitmq:namespace:rabbitmq:"
  "vernemq:namespace:vernemq:"
  "plantsuite:namespace:plantsuite:"
)

installed_count=0
found_components=()
for check in "${components_check[@]}"; do
  IFS=":" read -r name type ns selector <<<"$check"
  
  if [ "$type" = "namespace" ]; then
    if kubectl get namespace "$ns" &>/dev/null; then
      ((installed_count++))
      found_components+=("$name")
    fi
  elif [ "$type" = "deployment" ]; then
    # Verifica se há algum deployment retornado, não apenas exit code
    if [ -n "$(kubectl get deployment -n "$ns" -l "$selector" -o name 2>/dev/null)" ]; then
      ((installed_count++))
      found_components+=("$name")
    fi
  fi
done

total_components=${#components_check[@]}

if [ $installed_count -eq $total_components ]; then
  # Todos instalados → modo UPDATE
  UPDATE_MODE=true
  echo ""
  klog "Instalação completa detectada (${installed_count}/${total_components} componentes)."
  echo ""
  klog "Modo de atualização ativado."
  echo "Selecione quais componentes deseja atualizar:"
  echo ""
  echo "  0) Todos os componentes"
  echo "  1) metrics-server"
  echo "  2) cert-manager (+ issuers)"
  echo "  3) istio-system"
  echo "  4) istio-ingress"
  echo "  5) aspire"
  echo "  6) mongodb (operator + plantsuite-psmdb)"
  echo "  7) postgresql (operator + plantsuite-ppgc)"
  echo "  8) valkey"
  echo "  9) keycloak (operator + plantsuite-kc + realm)"
  echo " 10) rabbitmq (operator + plantsuite-rmq)"
  echo " 11) vernemq"
  echo " 12) plantsuite"
  echo ""
  read -p "Digite sua escolha (separados por vírgula para múltiplos, ex: 1,3,12): " component_choice
  
  # Parse escolhas
  IFS=',' read -r -a SELECTED_COMPONENTS <<<"$component_choice"
  
  # Trim espaços e validar
  declare -a CLEAN_COMPONENTS
  for comp in "${SELECTED_COMPONENTS[@]}"; do
    comp=$(echo "$comp" | xargs)  # trim
    CLEAN_COMPONENTS+=("$comp")
  done
  SELECTED_COMPONENTS=("${CLEAN_COMPONENTS[@]}")
  
  # Se escolheu 0 (todos), cria array com todos os números
  if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 0 " ]]; then
    SELECTED_COMPONENTS=(1 2 3 4 5 6 7 8 9 10 11 12)
  fi
  
elif [ $installed_count -gt 0 ]; then
  # Alguns instalados → instalação incompleta
  INCOMPLETE_INSTALL=true
  echo ""
  error "⚠️  INSTALAÇÃO INCOMPLETA DETECTADA!"
  echo ""
  echo "Componentes encontrados: ${installed_count}/${total_components}"
  echo "Componentes instalados: ${found_components[*]}"
  echo ""
  echo "Para evitar inconsistências:"
  echo "  1. Execute './tools/uninstall.sh' para remover todos os componentes"
  echo "  2. Execute './tools/install.sh' novamente para instalação completa"
  echo ""
  klog "Instalação cancelada."
  exit 1
else
  # Nenhum instalado → modo INSTALL normal
  SELECTED_COMPONENTS=(1 2 3 4 5 6 7 8 9 10 11 12)
fi

# Confirmação antes de prosseguir
echo ""
echo "📦 Contexto Kubernetes: $(kubectl config current-context)"
echo "🎯 Overlay: $SELECTED_OVERLAY"
if [ "$UPDATE_MODE" = true ]; then
  echo "🔄 Modo: Atualização"
elif [ "$INCOMPLETE_INSTALL" = true ]; then
  echo "⚠️  Modo: Instalação (com componentes existentes - NÃO RECOMENDADO)"
else
  echo "🆕 Modo: Instalação"
fi
echo ""
if [ "$UPDATE_MODE" = true ]; then
  read -p "Deseja realmente atualizar os componentes selecionados? (digite 'sim' para confirmar): " confirmation
else
  read -p "Deseja realmente instalar os componentes? (digite 'sim' para confirmar): " confirmation
fi
if [ "$confirmation" != "sim" ]; then
  if [ "$UPDATE_MODE" = true ]; then
    klog "Atualização cancelada pelo usuário."
  else
    klog "Instalação cancelada pelo usuário."
  fi
  exit 0
fi

echo ""
echo ""
# Componente 1: metrics-server
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 1 " ]]; then
  apply_component "apps/base/metrics-server/" "metrics-server"
  wait_deployment_ready "kube-system" "k8s-app=metrics-server" "metrics-server" "metrics-server"
fi

# Componente 2: cert-manager (+ issuers)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 2 " ]]; then
  echo ""
  apply_component "apps/base/cert-manager/" "cert-manager"
  wait_deployment_ready "cert-manager" "app.kubernetes.io/name=cert-manager" "cert-manager" "cert-manager"

  # Aguarda o webhook do cert-manager antes de aplicar os issuers
  wait_cert_manager_webhook_ready
  wait_with_spinner 15 "Aguardando propagação dos certificados TLS do webhook..."
  apply_component "apps/base/cert-manager/issuers/" "cert-manager issuers"
fi

# Componente 3: istio-system
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 3 " ]]; then
  echo ""
  apply_component "apps/base/istio-system/" "istio-system"
  wait_deployment_ready "istio-system" "app=istiod" "istiod" "istiod"
  wait_daemonset_ready "istio-system" "app=istio-cni-node" "istio-cni-node" "istio-cni-node"
  wait_daemonset_ready "istio-system" "app=ztunnel" "ztunnel" "ztunnel"
  wait_with_spinner 30 "Aguardando estabilização do istio-system..."
fi

# Componente 4: istio-ingress
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 4 " ]]; then
  echo ""
  apply_component "apps/base/istio-ingress/" "istio-ingress"
  wait_deployment_ready "istio-ingress" "app=gateway" "gateway" "istio-ingress gateway"
fi

# Componente 5: aspire
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 5 " ]]; then
  echo ""
  apply_component "apps/base/aspire/" "aspire"
  wait_deployment_ready "aspire" "app=aspire-dashboard" "aspire-dashboard" "aspire-dashboard"
fi

# Componente 6: mongodb (operator + plantsuite-psmdb)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 6 " ]]; then
  echo ""
  apply_component "apps/base/mongodb/" "mongodb operator"
  wait_deployment_ready "mongodb" "app.kubernetes.io/name=percona-server-mongodb-operator" "percona-server-mongodb-operator" "percona-server-mongodb-operator"
  apply_component "apps/base/mongodb/plantsuite-psmdb/" "plantsuite-psmdb"
  wait_psmdb_ready "mongodb" "plantsuite-psmdb" "plantsuite-psmdb (CR)"
  wait_statefulset_ready "mongodb" "app.kubernetes.io/instance=plantsuite-psmdb" "plantsuite-psmdb" "plantsuite-psmdb"
fi

# Componente 7: postgresql (operator + plantsuite-ppgc)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 7 " ]]; then
  echo ""
  apply_component "apps/base/postgresql/" "postgresql operator"
  wait_deployment_ready "postgresql" "app.kubernetes.io/name=percona-postgresql-operator" "percona-postgresql-operator" "percona-postgresql-operator"
  apply_component "apps/base/postgresql/plantsuite-ppgc/" "plantsuite-ppgc"
  wait_postgrescluster_ready "postgresql" "plantsuite-ppgc" "plantsuite-ppgc (CR)"
  wait_statefulset_ready "postgresql" "postgres-operator.crunchydata.com/cluster=plantsuite-ppgc" "plantsuite-ppgc" "plantsuite-ppgc"
fi

# Componente 8: valkey
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 8 " ]]; then
  echo ""
  generate_secure_password "apps/base/valkey/.env.secret" "password"
  apply_component "apps/base/valkey/" "valkey"
  wait_statefulset_ready "valkey" "app=valkey" "plantsuite-valkey" "valkey"
fi

# Componente 9: keycloak (operator + plantsuite-kc + realm)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 9 " ]]; then
  echo ""
  apply_component "apps/base/keycloak/" "keycloak operator"
  wait_deployment_ready "keycloak" "app.kubernetes.io/name=keycloak-operator" "keycloak-operator" "keycloak-operator"
  update_keycloak_secrets
  apply_component "apps/base/keycloak/plantsuite-kc/" "plantsuite-kc"
  wait_keycloak_ready "keycloak" "plantsuite-kc" "plantsuite-kc"
  wait_keycloak_realm_ready "keycloak" "plantsuite-kc-realm" "plantsuite-kc-realm"
fi

# Componente 10: rabbitmq (operator + plantsuite-rmq)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 10 " ]]; then
  echo ""
  apply_component "apps/base/rabbitmq/" "rabbitmq operator"
  wait_deployment_ready "rabbitmq" "app.kubernetes.io/name=rabbitmq-cluster-operator" "rabbitmq-cluster-operator" "rabbitmq-cluster-operator"
  apply_component "apps/base/rabbitmq/plantsuite-rmq/" "plantsuite-rmq"
  wait_rabbitmq_ready "rabbitmq" "plantsuite-rmq" "plantsuite-rmq (CR)"
  wait_statefulset_ready "rabbitmq" "app.kubernetes.io/name=plantsuite-rmq" "plantsuite-rmq-server" "plantsuite-rmq"
fi

# Componente 11: vernemq
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 11 " ]]; then
  echo ""
  update_vernemq_valkey_password
  apply_component "apps/base/vernemq/" "vernemq"
  wait_statefulset_ready "vernemq" "app.kubernetes.io/name=plantsuite-vmq" "plantsuite-vmq" "plantsuite-vmq"
fi

# Próximos passos: instalar outros componentes, aguardar serviços, obter secrets, etc.
## ...

# Componente 12: plantsuite
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 12 " ]]; then
  echo ""
  update_plantsuite_env
  apply_component "apps/base/plantsuite/" "plantsuite"
  wait_plantsuite_components_ready
fi
