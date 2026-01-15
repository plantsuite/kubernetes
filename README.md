# PlantSuite Kubernetes

## Visão geral

Manifestos [Kustomize](https://kustomize.io/) para instalar, atualizar e remover o stack [PlantSuite](https://www.plantsuite.com) em Kubernetes, com overlays para diferentes cenários (base, minimal, produção). Inclui scripts automatizados, configuração de dependências, certificados e instruções para acesso seguro aos serviços.
> 📚 Para guias detalhados sobre personalização, observabilidade e outros tópicos, consulte a pasta `docs/`.

## Camadas
- **base** (apps/base): HA com recursos enxutos; bom para testes próximos a produção com menos hardware.
- **minimal** (apps/overlays/minimal): mesmos requests/limits da base, mas 1 réplica; ideal para demos ou labs pequenos.
- **production** (apps/overlays/production): ponto de partida para produção; ajuste conforme tráfego/SLAs.

## Sizing sugerido para o cluster

| Overlay     | Nós | vCPU | RAM  | Disco  |   | **Total vCPU** | **Total RAM** | **Total Disco** |
|-------------|-----|------|------|--------|---|----------------|---------------|-----------------|
| minimal     | 1   | 4    | 16Gi | 150Gi  |   | **4**          | **16Gi**      | **150Gi**       |
| base        | 3   | 4    | 16Gi | 200Gi  |   | **12**         | **48Gi**      | **600Gi**       |
| production  | 3   | 8    | 32Gi | 500Gi  |   | **24**         | **96Gi**      | **1500Gi**      |

Valores em vCPU/RAM/Disco são por nó; colunas em negrito indicam o somatório por cluster. Recomendações mínimas; ajuste CPU/Mem/PVCs conforme tráfego, dados e SLOs observados.

## Instalação e Desinstalação

### Pré-requisitos

Antes de instalar, é necessário **obter o arquivo de licença `license.crt`** e **as credenciais de acesso ao registry `plantsuite.azurecr.io`**.

Solicite ambos ao suporte PlantSuite em [https://support.plantsuite.com](https://support.plantsuite.com). 

O arquivo de licença deve ser colocado em `apps/base/plantsuite/license.crt` e as credenciais (usuário e senha) devem ser inseridas no arquivo `apps/base/plantsuite/dockerconfig.json` e `apps/base/vernemq/dockerconfig.json`.

Além dos arquivos acima, verifique também as ferramentas abaixo instaladas e disponíveis no `PATH`:

- `kubectl`: necessário para interagir com o cluster Kubernetes e configurar o contexto desejado. Instruções oficiais de instalação: https://kubernetes.io/docs/tasks/tools/
- `helm`: necessário para o uso de `--enable-helm` com `kubectl kustomize` — confirme que está usando uma versão compatível, atualmente é a versão 3. Instruções oficiais de instalação: https://helm.sh/docs/intro/install/

### Ferramentas

- **Instalar**: `./tools/install.sh`
	- Aplica o stack na ordem correta, espera prontidão dos serviços e preenche secrets/configs necessários.
	- Como usar: rode a partir da raiz, escolha o overlay (base/minimal/production) e confirme com `sim`.
- **Desinstalar**: `./tools/uninstall.sh`
	- Remove tudo na ordem inversa e aguarda limpeza segura dos recursos.
	- Como usar: rode a partir da raiz e confirme com `sim`.

Notas:
- Precisa de `kubectl` configurado para o contexto desejado.
- Se o stack já estiver instalado, o install entra em modo atualização para reaplicar componentes específicos.

## Acesso aos Serviços

Após a instalação, os serviços são expostos via Istio Gateway com os seguintes domínios:

### URLs HTTP/HTTPS
- **Portal**: `portal.plantsuite.local`
- **Keycloak**: `account.plantsuite.local`
- **Aspire Dashboard**: `aspire-dashboard.plantsuite.local`
- **API Devices**: `devices.plantsuite.local`
- **API Entities**: `entities.plantsuite.local`
- **API Queries**: `queries.plantsuite.local`
- **API Tenants**: `tenants.plantsuite.local`
- **API Dashboards**: `dashboards.plantsuite.local`
- **API Notifications**: `notifications.plantsuite.local`
- **API Alarms**: `alarms.plantsuite.local`
- **API SPC**: `spc.plantsuite.local`
- **API Timeseries**: `timeseries.plantsuite.local`

### Serviços MQTT
- **VerneMQ (MQTT)**: `mqtt.plantsuite.local` (portas 1883/8883)
- **VerneMQ WebSocket**: `mqtt.plantsuite.local/mqtt`

### Obter o IP do Istio Ingress Gateway

```bash
kubectl get svc -n istio-ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Se estiver usando um cluster local (kind, minikube, etc.) sem LoadBalancer, use NodePort:

```bash
kubectl get svc -n istio-ingress gateway
```

### Configurar DNS Local

Adicione as entradas no arquivo `/etc/hosts` (Linux/macOS) ou `C:\Windows\System32\drivers\etc\hosts` (Windows), substituindo `<INGRESS_IP>` pelo IP obtido acima:

```
<INGRESS_IP> portal.plantsuite.local account.plantsuite.local aspire-dashboard.plantsuite.local devices.plantsuite.local entities.plantsuite.local queries.plantsuite.local tenants.plantsuite.local dashboards.plantsuite.local notifications.plantsuite.local alarms.plantsuite.local spc.plantsuite.local timeseries.plantsuite.local mqtt.plantsuite.local
```

### Confiar no Certificado SSL

Os certificados são gerados automaticamente pelo [cert-manager](https://cert-manager.io) usando um ClusterIssuer self-signed. Para acessar os serviços via HTTPS sem erros de segurança, é necessário extrair o certificado CA e adicioná-lo como confiável:

**1. Extrair o certificado CA:**
```bash
kubectl get secret plantsuite-wildcard-cert -n istio-ingress -o jsonpath='{.data.ca\.crt}' | base64 -d > plantsuite-ca.crt
```

**2. Importar no navegador/sistema:**

- **Linux**: Copie para `/usr/local/share/ca-certificates/` e execute `sudo update-ca-certificates`
- **macOS**: Abra `plantsuite-ca.crt` e adicione ao Keychain Access, marcando como "Sempre confiar"
- **Windows**: Clique duplo em `plantsuite-ca.crt` → Instalar Certificado → Armazenamento de Autoridades de Certificação Raiz Confiáveis
- **Firefox**: Preferências → Privacidade e Segurança → Certificados → Ver Certificados → Importar

Após configurar, acesse os serviços diretamente pelo navegador ou ferramentas de API:
- Portal: `https://portal.plantsuite.local`
- Keycloak Admin: `https://account.plantsuite.local`
- Aspire Dashboard: `https://aspire-dashboard.plantsuite.local`
