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

# Imprime uma linha limpando-a antes (usado por spinners/progress)
# Uso: cl_printf <format> [args...]
cl_printf() {
  # Sempre limpa a linha antes de imprimir
  printf "\r\033[K"
  # Em seguida imprime a mensagem formatada
  printf "$@"
}

# Verifica se o script está sendo executado a partir da raiz do repositório
assert_repo_root() {
  if [ ! -d "k8s" ] || [ ! -d "k8s/base" ] || [ ! -f "README.md" ]; then
    error "Este script deve ser executado a partir da raiz do repositório."
    echo "Pastas/arquivos esperados não encontrados: 'k8s/', 'k8s/base/', 'README.md'." >&2
    echo "Exemplo de uso: ./tools/install.sh" >&2
    exit 1
  fi
}

# Garante execução na raiz do repo
assert_repo_root

# Bibliotecas internas
# shellcheck source=tools/lib/metrics-server-tls-fix.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/metrics-server-tls-fix.sh"
# shellcheck source=tools/lib/k8s-wait.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/k8s-wait.sh"
# shellcheck source=tools/lib/secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/secrets.sh"



# Função para obter o caminho correto do componente baseado no overlay
get_component_path() {
  local base_path="$1"
  
  # Se um overlay foi selecionado, verifica se existe o componente no overlay
  if [ -n "$SELECTED_OVERLAY" ] && [ "$SELECTED_OVERLAY" != "base" ]; then
    # Remove o prefixo "k8s/base/" do caminho para obter o caminho relativo
    local relative_path="${base_path#k8s/base/}"
    local overlay_path="k8s/overlays/${SELECTED_OVERLAY}/${relative_path}"
    
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
    error_output=$(kubectl kustomize --enable-helm "$component_path" 2>&1 | kubectl apply --server-side --force-conflicts -f - 2>&1)
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

# Verifica se kubectl está instalado
if ! command -v kubectl &> /dev/null; then
  error "kubectl não encontrado. Instale o kubectl antes de continuar."
  exit 1
fi

# Verifica se helm está instalado (necessário para --enable-helm do kustomize)
if ! command -v helm &> /dev/null; then
  error "helm não encontrado. Instale o Helm antes de continuar (necessário para --enable-helm no kustomize)."
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
overlays_dir="k8s/overlays"
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
  "redis:namespace:redis:"
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
  echo "  8) redis"
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
  apply_component "k8s/base/metrics-server/" "metrics-server"
  metrics_server_detect_and_fix_tls
  wait_deployment_ready "kube-system" "k8s-app=metrics-server" "metrics-server" "metrics-server"
fi

# Componente 2: cert-manager (+ issuers)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 2 " ]]; then
  echo ""
  apply_component "k8s/base/cert-manager/" "cert-manager"
  wait_deployment_ready "cert-manager" "app.kubernetes.io/name=cert-manager" "cert-manager" "cert-manager"

  # Aguarda o webhook do cert-manager antes de aplicar os issuers
  wait_cert_manager_webhook_ready
  wait_with_spinner 90 "Aguardando estabilização do cert-manager webhook..."
  apply_component "k8s/base/cert-manager/issuers/" "cert-manager issuers"
fi

# Componente 3: istio-system
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 3 " ]]; then
  echo ""
  apply_component "k8s/base/istio-system/" "istio-system"
  wait_deployment_ready "istio-system" "app=istiod" "istiod" "istiod"
  wait_daemonset_ready "istio-system" "app=istio-cni-node" "istio-cni-node" "istio-cni-node"
  wait_daemonset_ready "istio-system" "app=ztunnel" "ztunnel" "ztunnel"
  wait_with_spinner 60 "Aguardando estabilização do istio-system..."
fi

# Componente 4: istio-ingress
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 4 " ]]; then
  echo ""
  apply_component "k8s/base/istio-ingress/" "istio-ingress"
  wait_deployment_ready "istio-ingress" "app=gateway" "gateway" "istio-ingress gateway"
fi

# Componente 5: aspire
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 5 " ]]; then
  echo ""
  apply_component "k8s/base/aspire/" "aspire"
  wait_deployment_ready "aspire" "app=aspire-dashboard" "aspire-dashboard" "aspire-dashboard"
fi

# Componente 6: mongodb (operator + plantsuite-psmdb)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 6 " ]]; then
  echo ""
  apply_component "k8s/base/mongodb/" "mongodb operator"
  wait_deployment_ready "mongodb" "app.kubernetes.io/name=percona-server-mongodb-operator" "percona-server-mongodb-operator" "percona-server-mongodb-operator"
  apply_component "k8s/base/mongodb/plantsuite-psmdb/" "plantsuite-psmdb"
  wait_psmdb_ready "mongodb" "plantsuite-psmdb" "plantsuite-psmdb (CR)"
  wait_statefulset_ready "mongodb" "app.kubernetes.io/instance=plantsuite-psmdb" "plantsuite-psmdb" "plantsuite-psmdb"
fi

# Componente 7: postgresql (operator + plantsuite-ppgc)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 7 " ]]; then
  echo ""
  apply_component "k8s/base/postgresql/" "postgresql operator"
  wait_deployment_ready "postgresql" "app.kubernetes.io/name=percona-postgresql-operator" "percona-postgresql-operator" "percona-postgresql-operator"
  apply_component "k8s/base/postgresql/plantsuite-ppgc/" "plantsuite-ppgc"
  wait_postgrescluster_ready "postgresql" "plantsuite-ppgc" "plantsuite-ppgc (CR)"
  wait_statefulset_ready "postgresql" "postgres-operator.crunchydata.com/cluster=plantsuite-ppgc" "plantsuite-ppgc" "plantsuite-ppgc"
fi

# Componente 8: redis
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 8 " ]]; then
  echo ""
  generate_secure_password "k8s/base/redis/.env.secret" "password"
  apply_component "k8s/base/redis/" "redis"
  wait_statefulset_ready "redis" "app=redis" "plantsuite-redis" "redis"
fi

# Componente 9: keycloak (operator + plantsuite-kc + realm)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 9 " ]]; then
  echo ""
  apply_component "k8s/base/keycloak/" "keycloak operator"
  wait_deployment_ready "keycloak" "app.kubernetes.io/name=keycloak-operator" "keycloak-operator" "keycloak-operator"
  update_keycloak_secrets
  apply_component "k8s/base/keycloak/plantsuite-kc/" "plantsuite-kc"
  wait_keycloak_ready "keycloak" "plantsuite-kc" "plantsuite-kc"
  wait_keycloak_realm_ready "keycloak" "plantsuite-kc-realm" "plantsuite-kc-realm"
fi

# Componente 10: rabbitmq (operator + plantsuite-rmq)
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 10 " ]]; then
  echo ""
  apply_component "k8s/base/rabbitmq/" "rabbitmq operator"
  wait_deployment_ready "rabbitmq" "app.kubernetes.io/name=rabbitmq-cluster-operator" "rabbitmq-cluster-operator" "rabbitmq-cluster-operator"
  apply_component "k8s/base/rabbitmq/plantsuite-rmq/" "plantsuite-rmq"
  wait_rabbitmq_ready "rabbitmq" "plantsuite-rmq" "plantsuite-rmq (CR)"
  wait_statefulset_ready "rabbitmq" "app.kubernetes.io/name=plantsuite-rmq" "plantsuite-rmq-server" "plantsuite-rmq"
fi

# Componente 11: vernemq
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 11 " ]]; then
  echo ""
  update_vernemq_secrets
  apply_component "k8s/base/vernemq/" "vernemq"
  wait_statefulset_ready "vernemq" "app.kubernetes.io/name=plantsuite-vmq" "plantsuite-vmq" "plantsuite-vmq"
fi

# Componente 12: plantsuite
if [[ " ${SELECTED_COMPONENTS[*]} " =~ " 12 " ]]; then
  echo ""
  update_plantsuite_env
  apply_component "k8s/base/plantsuite/" "plantsuite"
  if [ "$UPDATE_MODE" = true ]; then
    klog "Reiniciando componentes do Plantsuite..."
    # Reiniciar deployments
    deployments=$(kubectl get deployments -n plantsuite -l app.kubernetes.io/part-of=plantsuite -o jsonpath='{.items[*].metadata.name}')
    for dep in $deployments; do
      kubectl rollout restart deployment $dep -n plantsuite >/dev/null
    done
    # Reiniciar statefulsets
    statefulsets=$(kubectl get statefulsets -n plantsuite -l app.kubernetes.io/part-of=plantsuite -o jsonpath='{.items[*].metadata.name}')
    for sts in $statefulsets; do
      kubectl rollout restart statefulset $sts -n plantsuite >/dev/null
    done
  fi
  wait_plantsuite_components_ready
fi

# Limpeza opcional de senhas
echo ""
echo ""
echo "🔐 Limpeza de senhas armazenadas"
echo " - Por segurança, é recomendado remover as senhas armazenadas nos arquivos .env.secret após a instalação."
echo " - Você poderá consultar as senhas nos Secrets do Kubernetes, se necessário."
echo ""
read -p "Deseja remover as senhas? (s/n): " response
if [[ "$response" =~ ^[sS][iI][mM]|[sS]$ ]]; then
  cleanup_env_secrets
else
  klog "Limpeza de senhas pulada."
fi
