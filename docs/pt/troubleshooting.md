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

<ol type="1">
<li>Obtenha o IP correto do gateway do cluster:

   ```bash
   kubectl get svc -n istio-ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```</li>
<li>Edite o arquivo de hosts local adicionando todas as entradas dos serviços apontando para esse IP:
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
   ```</li>
<li>Limpe o cache de DNS do navegador (feche e reabra o navegador, ou use `about:networking#dns` → Clear DNS cache no Firefox). No Windows, rode `ipconfig /flushdns`.</li>
<li>Valide novamente com `getent hosts portal.plantsuite.local` — o IP retornado deve ser o do gateway.</li>
</ol>

## 2\. Aviso de certificado no navegador ("Sua conexão não é privada")

**Sintoma**: o navegador exibe "Sua conexão não é privada" / `NET::ERR_CERT_AUTHORITY_INVALID` ao acessar qualquer serviço `*.plantsuite.local` via HTTPS.

**Causa**: o cluster usa um certificado auto-assinado (ClusterIssuer `selfsigned` do cert-manager), esperado em ambientes de demonstração/homologação. O navegador não confia na CA até que o certificado seja importado manualmente.

### Como resolver

<ol type="1">
<li>Extraia o certificado CA do cluster:

   ```bash
   kubectl get secret plantsuite-wildcard-cert -n istio-ingress -o jsonpath='{.data.ca\.crt}' | base64 -d > plantsuite-ca.crt
   ```</li>
<li>Importe o arquivo `plantsuite-ca.crt` no sistema operacional ou navegador, conforme o caso:

   - **Linux (Chrome, Chromium, Edge)** — usam a trust store do sistema:

     ```bash
     sudo cp plantsuite-ca.crt /usr/local/share/ca-certificates/plantsuite-ca.crt
     sudo update-ca-certificates
     ```

     Confirmar com `1 added, 0 removed; done.`.

   - **macOS**:
     <ol type="1">
     <li>Abra o arquivo `plantsuite-ca.crt`.</li>
     <li>Adicione ao Keychain Access.</li>
     <li>Marque a política de confiança como "Sempre confiar".</li>
     </ol>

   - **Windows (Chrome, Edge)**:
     <ol type="1">
     <li>Dê um duplo clique no arquivo `plantsuite-ca.crt`.</li>
     <li>Clique em "Instalar Certificado...".</li>
     <li>Escolha "Máquina Local" (requer administrador) → Avançar.</li>
     <li>Escolha "Colocar todos os certificados no repositório a seguir".</li>
     <li>Clique em "Procurar" e selecione "Autoridades Raiz Confiáveis" (Trusted Root Certification Authorities).</li>
     <li>Avançar → Concluir. Confirme o aviso de segurança com "Sim".</li>
     </ol>

   - **Firefox (qualquer SO)** — mantém trust store própria, separada do sistema:
     <ol type="1">
     <li>Abra o Firefox e digite `about:preferences` na barra de endereços.</li>
     <li>Vá em "Privacy & Security" → "Certificates" → "View Certificates".</li>
     <li>Na aba "Authorities", clique em "Import".</li>
     <li>Selecione o arquivo `plantsuite-ca.crt`.</li>
     <li>Marque "Trust this CA to identify websites" e clique em OK.</li>
     </ol></li>
<li>Feche e reabra o navegador. Acesse novamente — o cadeado deve aparecer sem aviso de certificado.</li>
</ol>

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

<ol type="1">
<li>Atualize o DNS da LAN (ou o `/etc/hosts` local) para apontar todos os hosts `*.plantsuite.local` para o IP do LoadBalancer obtido acima.</li>
<li>Se o pool do MetalLB estiver esgotado (apenas um IP `/32` já em uso pelo gateway), expanda o pool antes de provisionar novos LoadBalancers. Para conferir o pool atual:

   ```bash
   kubectl get IPAddressPool -A -o yaml
   ```</li>
</ol>

## 4\. Redis preso em loop de bootstrap (REPLICAS=6 em ambiente demo)

**Sintoma**: o Pod `plantsuite-redis-0` (namespace `redis`) fica em loop no log do container `init-cluster` com a mensagem `[init-cluster] Waiting for plantsuite-redis-1...`, a `readinessProbe` falha repetidamente, e o Pod acumula restarts. O log do container `redis` mostra `REPLICAS=6 PRIMARIES=3` e `Running mode=cluster`, mesmo em um cluster demo (single-node) onde só o `plantsuite-redis-0` deveria existir.

**Causa provável**: o StatefulSet em runtime no cluster tem `replicas=6` (estado resultante de um deploy anterior da base/production), e o overlay demo (`replicas: 1`) nunca foi aplicado sobre ele. O script `init-cluster.sh` lê o valor `6` direto do StatefulSet, entra no caminho de inicialização em modo cluster, e fica aguardando 5 peers (`plantsuite-redis-1` até `plantsuite-redis-5`) que nunca sobem, pois o ambiente não os provisiona. O `readinessProbe` (que avalia `cluster_state:ok` quando `REPLICAS>1`) também falha, perpetuando o ciclo de restarts.

### Como diagnosticar

Verifique quantas réplicas o StatefulSet tem em runtime:

```bash
kubectl get statefulset plantsuite-redis -n redis -o jsonpath='{.spec.replicas}'
```

Se retornar `6`, o overlay demo não está aplicado.

Inspecione o log do init container que detecta o número de réplicas:

```bash
kubectl logs plantsuite-redis-0 -c get-replicas -n redis
```

A saída deve mostrar `Detected N replicas from StatefulSet`, onde `N` reflete o `.spec.replicas` em runtime.

Confirme o modo de execução e o loop no log do Redis:

```bash
kubectl logs plantsuite-redis-0 -c redis -n redis --tail=30
```

Procure por `Running mode=cluster` e pelas mensagens repetidas de espera por `plantsuite-redis-1`.

Compare com o manifest renderizado pelo overlay demo (esperado `replicas: 1`):

```bash
kubectl kustomize k8s/overlays/demo/redis/ | grep -A2 replicas
```

Se o valor renderizado for `1` mas o cluster tem `6`, confirma-se o desalinhamento entre o manifest desejado e o estado em runtime.

### Como corrigir (em janela de manutenção)

<ol type="1">
<li>Confirme o contexto-alvo antes de qualquer alteração:

   ```bash
   kubectl config current-context
   ```</li>
<li>Faça backup do StatefulSet atual (opcional, recomendado):

   ```bash
   kubectl get statefulset plantsuite-redis -n redis -o yaml > /tmp/redis-sts-backup.yaml
   ```</li>
<li>Deletar o StatefulSet antigo. <strong>Atenção</strong>: os PVCs vinculados <strong>NÃO</strong> são tocados por essa operação; os dados do Redis são preservados.

   ```bash
   kubectl delete statefulset plantsuite-redis -n redis
   ```</li>
<li>Aplicar o overlay demo (que renderiza `replicas: 1`):

   ```bash
   kubectl apply -k k8s/overlays/demo/redis/
   ```</li>
<li>Acompanhar a subida do Pod:

   ```bash
   kubectl get pods -n redis -l app=redis -w
   ```

   Aguarde até `plantsuite-redis-0` atingir `1/1 Running` (Ready).</li>
</ol>

### Pós-remediação (validação)

Confirme que o número de réplicas detectado voltou a `1`:

```bash
kubectl logs plantsuite-redis-0 -c get-replicas -n redis
```

Deve mostrar `Detected 1 replicas`.

Confirme a mudança de modo de execução:

```bash
kubectl logs plantsuite-redis-0 -c redis -n redis --tail=20
```

Deve mostrar `Running mode=standalone`.

Confirme o estado do Pod:

```bash
kubectl get pod plantsuite-redis-0 -n redis
```

Deve mostrar `1/1 Running` com `READY 1/1`.

### Notas

- **PVCs persistem após `delete statefulset`**: os volumes (`data-plantsuite-redis-0`) não são removidos pela exclusão do StatefulSet, então os dados do Redis são mantidos. Remova o PVC explicitamente apenas se quiser zerar o estado do Redis:
  ```bash
  kubectl delete pvc data-plantsuite-redis-0 -n redis
  ```
- **`kubectl apply -k` direto sem delete pode não convergir** de `replicas=6` para `replicas=1` por conta do 3-way merge do Kubernetes preservar o campo `replicas` em runtime. O fluxo `delete` + `apply -k` é mais seguro para corrigir o desalinhamento.
- **readinessProbe branch-aware (hardening preventivo)**: a `readinessProbe` do `k8s/base/redis/statefulset.yaml` (linhas 201-219) foi ajustada para distinguir modo `standalone` (`REPLICAS=1`) de modo `cluster` (`REPLICAS>1`), evitando falsos negativos de prontidão em ambientes demo. Essa mudança é uma melhoria de hardening e <strong>não resolve</strong> o incidente operacional descrito acima — a causa raiz é o desalinhamento entre o overlay aplicado e o estado em runtime. A decisão está registrada em `wiki/decisions/redis-readiness-probe-branch-aware.md` e a convenção de probes em `wiki/conventions/probes.md`.

## Observações

- **Ping falha mas HTTPS funciona**: em clusters com MetalLB modo L2, o VIP do LoadBalancer não responde ICMP. Teste com `curl` ou `openssl s_client` em vez de `ping` para validar o acesso.
- **Lista completa de hosts**: ver a seção "Acesso aos Serviços" do `README.md` na raiz do repositório.
- **PVCs persistem após exclusão de StatefulSet**: ao deletar um StatefulSet (ex.: Redis), os PVCs vinculados não são removidos automaticamente — os dados são preservados. Remova os PVCs explicitamente apenas se desejar zerar o estado.
