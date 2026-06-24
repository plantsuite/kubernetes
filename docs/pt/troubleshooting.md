# Troubleshooting de Acesso aos Serviços

Este guia cobre os problemas mais comuns ao acessar os serviços do PlantSuite via navegador, depois que o cluster está instalado e os serviços estão saudáveis. Para cada sintoma, são apresentados a causa provável, como diagnosticar e como corrigir. A lista completa de hosts e o IP do gateway do cluster estão documentados na seção "Acesso aos Serviços" do `README.md` na raiz do repositório.

## 1\. Portal não carrega / timeout

**Sintoma**: ao acessar `https://portal.plantsuite.local/` o navegador demora indefinidamente ou retorna timeout. A página nunca chega a renderizar.

**Causa provável**: o DNS local está apontando para o IP errado do cluster (geralmente o IP do node em vez do IP do LoadBalancer do Istio Gateway).

### Como diagnosticar

Verifique qual IP o sistema está resolvendo para o host do portal:

```bash
# Linux / macOS
getent hosts portal.plantsuite.local
# deve retornar o IP do gateway (ex.: 192.168.1.81), não o IP do node
```

```cmd
:: Windows (Prompt de Comando ou PowerShell)
nslookup portal.plantsuite.local
```

```bash
# Qualquer SO: observar o IP entre colchetes
ping portal.plantsuite.local
```

Se o IP retornado for o do node (ex.: `192.168.1.80`) em vez do do gateway (ex.: `192.168.1.81`), o DNS está errado.

> **Nota sobre ping em MetalLB L2**: em clusters com MetalLB em modo L2, o VIP do LoadBalancer responde a TCP (portas 80/443/etc.) mas não responde a ICMP/ping. `ping` falhar mesmo com o DNS correto é comportamento esperado, não indica erro. Use `curl` ou `openssl s_client` para validar o acesso.

### Como corrigir

1. Obtenha o IP correto do gateway do cluster:

   ```bash
   kubectl get svc -n istio-ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```

2. Edite o arquivo de hosts local adicionando todas as entradas dos serviços apontando para esse IP:
   - Linux / macOS: `/etc/hosts`
   - Windows: `C:\Windows\System32\drivers\etc\hosts` (abrir como administrador)

   Substitua `<INGRESS_IP>` pelo IP obtido no passo anterior:

   ```text
   <INGRESS_IP> gateway.plantsuite.local
   <INGRESS_IP> gateway-ui.plantsuite.local
   <INGRESS_IP> account.plantsuite.local
   <INGRESS_IP> alarms.plantsuite.local
   <INGRESS_IP> aspire-dashboard.plantsuite.local
   <INGRESS_IP> dashboards.plantsuite.local
   <INGRESS_IP> devices.plantsuite.local
   <INGRESS_IP> entities.plantsuite.local
   <INGRESS_IP> mqtt.plantsuite.local
   <INGRESS_IP> notifications.plantsuite.local
   <INGRESS_IP> portal.plantsuite.local
   <INGRESS_IP> queries.plantsuite.local
   <INGRESS_IP> spc.plantsuite.local
   <INGRESS_IP> tenants.plantsuite.local
   <INGRESS_IP> timeseries.plantsuite.local
   ```

3. Limpe o cache de DNS do navegador (feche e reabra o navegador, ou use `about:networking#dns` → Clear DNS cache no Firefox). No Windows, rode `ipconfig /flushdns`.

4. Valide novamente com `getent hosts portal.plantsuite.local` — o IP retornado deve ser o do gateway.

## 2\. Aviso de certificado no navegador ("Sua conexão não é privada")

**Sintoma**: o navegador exibe "Sua conexão não é privada" / `NET::ERR_CERT_AUTHORITY_INVALID` ao acessar qualquer serviço `*.plantsuite.local` via HTTPS.

**Causa**: o cluster usa um certificado auto-assinado (ClusterIssuer `selfsigned` do cert-manager), esperado em ambientes de demonstração/homologação. O navegador não confia na CA até que o certificado seja importado manualmente.

### Como resolver

1. Extraia o certificado CA do cluster:

   ```bash
   kubectl get secret plantsuite-wildcard-cert -n istio-ingress -o jsonpath='{.data.ca\.crt}' | base64 -d > plantsuite-ca.crt
   ```

2. Importe o arquivo `plantsuite-ca.crt` no sistema operacional ou navegador, conforme o caso:

   - **Linux (Chrome, Chromium, Edge)** — usam a trust store do sistema:

     ```bash
     sudo cp plantsuite-ca.crt /usr/local/share/ca-certificates/plantsuite-ca.crt
     sudo update-ca-certificates
     ```

     Confirmar com `1 added, 0 removed; done.`.

   - **macOS**:
     1\. Abra o arquivo `plantsuite-ca.crt`.
     2\. Adicione ao Keychain Access.
     3\. Marque a política de confiança como "Sempre confiar".

   - **Windows (Chrome, Edge)**:
     1\. Dê um duplo clique no arquivo `plantsuite-ca.crt`.
     2\. Clique em "Instalar Certificado...".
     3\. Escolha "Máquina Local" (requer administrador) → Avançar.
     4\. Escolha "Colocar todos os certificados no repositório a seguir".
     5\. Clique em "Procurar" e selecione "Autoridades Raiz Confiáveis" (Trusted Root Certification Authorities).
     6\. Avançar → Concluir. Confirme o aviso de segurança com "Sim".

   - **Firefox (qualquer SO)** — mantém trust store própria, separada do sistema:
     1\. Abra o Firefox e digite `about:preferences` na barra de endereços.
     2\. Vá em "Privacy & Security" → "Certificates" → "View Certificates".
     3\. Na aba "Authorities", clique em "Import".
     4\. Selecione o arquivo `plantsuite-ca.crt`.
     5\. Marque "Trust this CA to identify websites" e clique em OK.

3. Feche e reabra o navegador. Acesse novamente — o cadeado deve aparecer sem aviso de certificado.

> **Ambiente de produção**: em produção, configurar um certificado válido na rede (Let's Encrypt ou CA corporativa) para evitar a importação manual em cada máquina. Esta etapa de importação manual é necessária apenas para ambientes de demonstração/homologação.

## 3\. DNS resolve IP errado (node vs LoadBalancer)

**Sintoma**: `getent hosts` ou `ping` mostra o IP do node (ex.: `192.168.1.80`) em vez do IP do gateway LoadBalancer (ex.: `192.168.1.81`).

### Explicação

- O **node** (`.80`) é o servidor que gerencia o cluster (control plane do MicroK8s, porta `16443`). Ele não serve tráfego de navegador na porta 443.
- O **LoadBalancer** (`.81`) é o endpoint correto, onde o Istio Gateway escuta nas portas `80`/`443`/`1883`/`8883`/`15021`.
- O IP do gateway é atribuído pelo MetalLB a partir do pool configurado no cluster.

### Como diagnosticar

```bash
# Verificar qual IP o LoadBalancer recebeu (coluna EXTERNAL-IP)
kubectl get svc -n istio-ingress gateway -o wide
```

```bash
# Testar TLS no IP do gateway — deve entregar o certificado do plantsuite
openssl s_client -connect <IP_DO_GATEWAY>:443 -servername portal.plantsuite.local
```

```bash
# Testar TLS no IP do node — deve falhar (o node não serve TLS na 443)
openssl s_client -connect <IP_DO_NODE>:443
```

### Como corrigir

1. Atualize o DNS da LAN (ou o `/etc/hosts` local) para apontar todos os hosts `*.plantsuite.local` para o IP do LoadBalancer obtido acima.

2. Se o pool do MetalLB estiver esgotado (apenas um IP `/32` já em uso pelo gateway), expanda o pool antes de provisionar novos LoadBalancers. Para conferir o pool atual:

   ```bash
   kubectl get IPAddressPool -A -o yaml
   ```

## Observações

- **Ping falha mas HTTPS funciona**: em clusters com MetalLB modo L2, o VIP do LoadBalancer não responde ICMP. Teste com `curl` ou `openssl s_client` em vez de `ping` para validar o acesso.
- **Lista completa de hosts**: ver a seção "Acesso aos Serviços" do `README.md` na raiz do repositório.
