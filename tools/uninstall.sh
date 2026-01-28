#!/bin/bash
# uninstall.sh - Script de desinstalação automatizada dos componentes Kubernetes
#
# Este script remove os componentes na ordem inversa da instalação,
# aguardando cada recurso ser completamente removido antes de prosseguir.

# Variável global para armazenar o overlay selecionado
SELECTED_OVERLAY=""

# Função para exibir erros
error() {
  echo -e "\033[1;31m[ERRO]\033[0m $1" >&2
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
    echo "Exemplo de uso: ./tools/uninstall.sh" >&2
    exit 1
  fi
}

# Garante execução na raiz do repo
assert_repo_root

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

# Função para remover um componente kustomize
remove_component() {
  local base_path="$1"
  local name="$2"
  local component_path=$(get_component_path "$base_path")
  
  if [ "$component_path" != "$base_path" ]; then
    klog "Removendo $name (overlay: $SELECTED_OVERLAY) - $component_path"
  else
    klog "Removendo $name - $component_path"
  fi
  
  output=$(kubectl kustomize --enable-helm "$component_path" 2>&1 | kubectl delete -f - --ignore-not-found=true 2>&1)
  if [ $? -eq 0 ]; then
    klog "$name removido com sucesso."
  else
    warning "Falha ao remover $name. Continuando..."
    echo "$output" >&2
  fi
}

# Função para aguardar namespace ser removido
wait_namespace_deleted() {
  local namespace="$1"
  local timeout=120
  local elapsed=0
  local interval=2
  local spinner=("|" "/" "-" "\\")
  
  # Verifica se o namespace existe antes de aguardar (usando exit code)
  if ! kubectl get namespace "$namespace" &>/dev/null; then
    klog "Namespace $namespace não existe ou já foi removido."
    return 0
  fi
  
  while [ $elapsed -lt $timeout ]; do
    if ! kubectl get namespace "$namespace" &>/dev/null; then
      printf "\r\033[K"
      klog "Namespace $namespace foi removido."
      return 0
    fi
    idx=$(( (elapsed / interval) % 4 ))
    printf "\rAguardando namespace %s ser removido... %s" "$namespace" "${spinner[$idx]}"
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  printf "\r\033[K"
  warning "Namespace $namespace não foi removido no tempo esperado. Continuando..."
  return 0
}

# Função para aguardar StatefulSet ser removido
wait_statefulset_deleted() {
  local namespace="$1"
  local name="$2"
  local timeout=120
  local elapsed=0
  local interval=2
  local spinner=("|" "/" "-" "\\")
  
  # Verifica se o StatefulSet existe antes de aguardar (usando exit code)
  if ! kubectl get sts "$name" -n "$namespace" &>/dev/null; then
    klog "StatefulSet $name não existe ou já foi removido."
    return 0
  fi
  
  while [ $elapsed -lt $timeout ]; do
    if ! kubectl get sts "$name" -n "$namespace" &>/dev/null; then
      printf "\r\033[K"
      klog "StatefulSet $name removido."
      return 0
    fi
    idx=$(( (elapsed / interval) % 4 ))
    printf "\rAguardando StatefulSet %s ser removido... %s" "$name" "${spinner[$idx]}"
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  printf "\r\033[K"
  warning "StatefulSet $name não foi removido no tempo esperado. Continuando..."
  return 0
}

# Função para aguardar Custom Resource ser removido
wait_cr_deleted() {
  local kind="$1"
  local name="$2"
  local namespace="$3"
  local timeout=120
  local elapsed=0
  local interval=2
  local spinner=("|" "/" "-" "\\")
  
  # Verifica se o CR existe antes de aguardar (usando exit code ao invés de output vazio)
  if ! kubectl get "$kind" "$name" -n "$namespace" &>/dev/null; then
    klog "$kind $name não existe ou já foi removido."
    return 0
  fi
  
  while [ $elapsed -lt $timeout ]; do
    if ! kubectl get "$kind" "$name" -n "$namespace" &>/dev/null; then
      printf "\r\033[K"
      klog "$kind $name removido."
      return 0
    fi
    idx=$(( (elapsed / interval) % 4 ))
    printf "\rAguardando %s %s ser removido... %s" "$kind" "$name" "${spinner[$idx]}"
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  printf "\r\033[K"
  warning "$kind $name não foi removido no tempo esperado. Continuando..."
  return 0
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
klog "Selecione o overlay utilizado na instalação:"
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
  chosen_index=$((overlay_choice - 2))
  if [ $chosen_index -ge 0 ] && [ $chosen_index -lt ${#AVAILABLE_OVERLAYS[@]} ]; then
    SELECTED_OVERLAY="${AVAILABLE_OVERLAYS[$chosen_index]}"
  else
    warning "Escolha inválida. Usando 'base'."
    SELECTED_OVERLAY="base"
  fi
fi

# Confirmação antes de prosseguir
echo ""
echo "⚠️  ATENÇÃO: Todos os componentes serão removidos do cluster!"
echo ""
echo "📦 Contexto Kubernetes: $(kubectl config current-context)"
echo "🎯 Overlay: $SELECTED_OVERLAY"
echo ""
read -p "Tem certeza que deseja continuar? (digite 'sim' para confirmar): " confirmation
if [ "$confirmation" != "sim" ]; then
  klog "Desinstalação cancelada pelo usuário."
  exit 0
fi

echo ""
klog "Iniciando desinstalação dos componentes (ordem inversa)..."
echo ""
remove_component "k8s/base/plantsuite/" "plantsuite"
wait_namespace_deleted "plantsuite"

echo ""
remove_component "k8s/base/vernemq/" "vernemq"
wait_statefulset_deleted "vernemq" "app.kubernetes.io/name=plantsuite-vmq" "plantsuite-vmq"
wait_namespace_deleted "vernemq"

echo ""
remove_component "k8s/base/rabbitmq/plantsuite-rmq/" "plantsuite-rmq"
wait_cr_deleted "rabbitmqcluster" "plantsuite-rmq" "rabbitmq"
wait_statefulset_deleted "rabbitmq" "app.kubernetes.io/name=plantsuite-rmq" "plantsuite-rmq"
remove_component "k8s/base/rabbitmq/" "rabbitmq operator"
wait_namespace_deleted "rabbitmq"

echo ""
remove_component "k8s/base/keycloak/plantsuite-kc/" "plantsuite-kc"
wait_cr_deleted "keycloak" "plantsuite-kc" "keycloak"
wait_cr_deleted "keycloakrealmimport" "plantsuite-kc-realm" "keycloak"
remove_component "k8s/base/keycloak/" "keycloak operator"
wait_namespace_deleted "keycloak"

echo ""
remove_component "k8s/base/redis/" "redis"
wait_statefulset_deleted "redis" "app=redis" "plantsuite-redis"
wait_namespace_deleted "redis"

echo ""
remove_component "k8s/base/postgresql/plantsuite-ppgc/" "plantsuite-ppgc"
wait_cr_deleted "postgrescluster" "plantsuite-ppgc" "postgresql"
wait_statefulset_deleted "postgresql" "postgres-operator.crunchydata.com/cluster=plantsuite-ppgc" "plantsuite-ppgc"
remove_component "k8s/base/postgresql/" "postgresql operator"
wait_namespace_deleted "postgresql"

echo ""
remove_component "k8s/base/mongodb/plantsuite-psmdb/" "plantsuite-psmdb"
wait_cr_deleted "psmdb" "plantsuite-psmdb" "mongodb"
wait_statefulset_deleted "mongodb" "app.kubernetes.io/instance=plantsuite-psmdb" "plantsuite-psmdb"
remove_component "k8s/base/mongodb/" "mongodb operator"
wait_namespace_deleted "mongodb"

echo ""
remove_component "k8s/base/aspire/" "aspire"
wait_namespace_deleted "aspire"

echo ""
remove_component "k8s/base/istio-ingress/" "istio-ingress"
wait_namespace_deleted "istio-ingress"

echo ""
remove_component "k8s/base/istio-system/" "istio-system"
wait_namespace_deleted "istio-system"

echo ""
remove_component "k8s/base/cert-manager/issuers/" "cert-manager issuers"
remove_component "k8s/base/cert-manager/" "cert-manager"
wait_namespace_deleted "cert-manager"

echo ""
remove_component "k8s/base/metrics-server/" "metrics-server"

echo ""
klog "Desinstalação concluída com sucesso!"
