# Service Access Troubleshooting

This guide covers the most common issues encountered when accessing PlantSuite services through a browser, after the cluster is installed and the services are healthy. For each symptom, the likely cause, how to diagnose it, and how to fix it are presented. The full list of hosts and the cluster gateway IP are documented in the "Acesso aos Serviços" / "Service Access" section of the `README.md` at the repository root.

## 1\. Portal does not load / timeout

**Symptom**: when accessing `https://portal.plantsuite.local/`, the browser hangs indefinitely or returns a timeout. The page never renders.

**Likely cause**: the local DNS is pointing to the wrong cluster IP (usually the node IP instead of the Istio Gateway LoadBalancer IP).

### How to diagnose

Check which IP the system is resolving for the portal host:

```bash
# Linux / macOS
getent hosts portal.plantsuite.local
# should return the gateway IP (e.g., 192.168.1.81), not the node IP
```

```cmd
:: Windows (Command Prompt or PowerShell)
nslookup portal.plantsuite.local
```

```bash
# Any OS: observe the IP in square brackets
ping portal.plantsuite.local
```

If the returned IP is the node's (e.g., `192.168.1.80`) instead of the gateway's (e.g., `192.168.1.81`), the DNS is wrong.

> **Note on ping with MetalLB L2**: in clusters running MetalLB in L2 mode, the LoadBalancer VIP responds to TCP (ports 80/443/etc.) but does not respond to ICMP/ping. `ping` failing even with correct DNS is expected behavior and does not indicate an error. Use `curl` or `openssl s_client` to validate access.

### How to fix

<ol type="1">
<li>Obtain the correct gateway IP from the cluster:

   ```bash
   kubectl get svc -n istio-ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```</li>
<li>Edit the local hosts file, adding all service entries pointing to that IP:
   - Linux / macOS: `/etc/hosts`
   - Windows: `C:\Windows\System32\drivers\etc\hosts` (open as administrator)

   Replace `<INGRESS_IP>` with the IP obtained in the previous step:

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
<li>Clear the browser DNS cache (close and reopen the browser, or use `about:networking#dns` → Clear DNS cache in Firefox). On Windows, run `ipconfig /flushdns`.</li>
<li>Validate again with `getent hosts portal.plantsuite.local` — the returned IP should be the gateway's.</li>
</ol>

## 2\. Browser certificate warning ("Your connection is not private")

**Symptom**: the browser displays "Your connection is not private" / `NET::ERR_CERT_AUTHORITY_INVALID` when accessing any `*.plantsuite.local` service over HTTPS.

**Cause**: the cluster uses a self-signed certificate (`selfsigned` ClusterIssuer from cert-manager), which is expected in demonstration/staging environments. The browser does not trust the CA until the certificate is imported manually.

### How to resolve

<ol type="1">
<li>Extract the CA certificate from the cluster:

   ```bash
   kubectl get secret plantsuite-wildcard-cert -n istio-ingress -o jsonpath='{.data.ca\.crt}' | base64 -d > plantsuite-ca.crt
   ```</li>
<li>Import the `plantsuite-ca.crt` file into the operating system or browser, as appropriate:

   - **Linux (Chrome, Chromium, Edge)** — use the system trust store:

     ```bash
     sudo cp plantsuite-ca.crt /usr/local/share/ca-certificates/plantsuite-ca.crt
     sudo update-ca-certificates
     ```

     Confirm the output shows `1 added, 0 removed; done.`.

   - **macOS**:
     <ol type="1">
     <li>Open the `plantsuite-ca.crt` file.</li>
     <li>Add it to Keychain Access.</li>
     <li>Set the trust policy to "Always trust".</li>
     </ol>

   - **Windows (Chrome, Edge)**:
     <ol type="1">
     <li>Double-click the `plantsuite-ca.crt` file.</li>
     <li>Click "Install Certificate...".</li>
     <li>Choose "Local Machine" (requires administrator) → Next.</li>
     <li>Choose "Place all certificates in the following store".</li>
     <li>Click "Browse" and select "Trusted Root Certification Authorities".</li>
     <li>Next → Finish. Confirm the security warning with "Yes".</li>
     </ol>

   - **Firefox (any OS)** — maintains its own trust store, separate from the system:
     <ol type="1">
     <li>Open Firefox and type `about:preferences` in the address bar.</li>
     <li>Go to "Privacy & Security" → "Certificates" → "View Certificates".</li>
     <li>On the "Authorities" tab, click "Import".</li>
     <li>Select the `plantsuite-ca.crt` file.</li>
     <li>Check "Trust this CA to identify websites" and click OK.</li>
     </ol></li>
<li>Close and reopen the browser. Access the service again — the padlock should appear without a certificate warning.</li>
</ol>

> **Production environment**: in production, configure a valid certificate on the network (Let's Encrypt or a corporate CA) to avoid manual import on each machine. This manual import step is only required for demonstration/staging environments.

## 3\. DNS resolves to the wrong IP (node vs LoadBalancer)

**Symptom**: `getent hosts` or `ping` shows the node IP (e.g., `192.168.1.80`) instead of the LoadBalancer gateway IP (e.g., `192.168.1.81`).

### Explanation

- The **node** (`.80`) is the server that manages the cluster (MicroK8s control plane, port `16443`). It does not serve browser traffic on port 443.
- The **LoadBalancer** (`.81`) is the correct endpoint, where the Istio Gateway listens on ports `80`/`443`/`1883`/`8883`/`15021`.
- The gateway IP is assigned by MetalLB from the pool configured on the cluster.

### How to diagnose

```bash
# Check which IP the LoadBalancer received (EXTERNAL-IP column)
kubectl get svc -n istio-ingress gateway -o wide
```

```bash
# Test TLS on the gateway IP — should return the plantsuite certificate
openssl s_client -connect <GATEWAY_IP>:443 -servername portal.plantsuite.local
```

```bash
# Test TLS on the node IP — should fail (the node does not serve TLS on 443)
openssl s_client -connect <NODE_IP>:443
```

### How to fix

<ol type="1">
<li>Update the LAN DNS (or the local `/etc/hosts`) so all `*.plantsuite.local` hosts point to the LoadBalancer IP obtained above.</li>
<li>If the MetalLB pool is exhausted (only a single `/32` IP already in use by the gateway), expand the pool before provisioning new LoadBalancers. To inspect the current pool:

   ```bash
   kubectl get IPAddressPool -A -o yaml
   ```</li>
</ol>

## 4\. Redis stuck in bootstrap loop (REPLICAS=6 in demo environment)

**Symptom**: the `plantsuite-redis-0` Pod (namespace `redis`) is stuck in a loop in the `init-cluster` container log, repeating `[init-cluster] Waiting for plantsuite-redis-1...`, the `readinessProbe` keeps failing, and the Pod accumulates restarts. The `redis` container log shows `REPLICAS=6 PRIMARIES=3` and `Running mode=cluster`, even in a demo (single-node) cluster where only `plantsuite-redis-0` should exist.

**Likely cause**: the StatefulSet in runtime on the cluster has `replicas=6` (the state left by a previous base/production deploy), and the demo overlay (`replicas: 1`) was never applied on top of it. The `init-cluster.sh` script reads the value `6` directly from the StatefulSet, enters the cluster-mode bootstrap path, and waits for 5 peers (`plantsuite-redis-1` through `plantsuite-redis-5`) that never come up because the environment does not provision them. The `readinessProbe` (which evaluates `cluster_state:ok` when `REPLICAS>1`) also fails, perpetuating the restart loop.

### How to diagnose

Check how many replicas the StatefulSet has in runtime:

```bash
kubectl get statefulset plantsuite-redis -n redis -o jsonpath='{.spec.replicas}'
```

If it returns `6`, the demo overlay is not applied.

Inspect the log of the init container that detects the replica count:

```bash
kubectl logs plantsuite-redis-0 -c get-replicas -n redis
```

The output should show `Detected N replicas from StatefulSet`, where `N` matches the runtime `.spec.replicas`.

Confirm the execution mode and the wait loop in the Redis log:

```bash
kubectl logs plantsuite-redis-0 -c redis -n redis --tail=30
```

Look for `Running mode=cluster` and the repeated messages waiting for `plantsuite-redis-1`.

Compare with the manifest rendered by the demo overlay (expected `replicas: 1`):

```bash
kubectl kustomize k8s/overlays/demo/redis/ | grep -A2 replicas
```

If the rendered value is `1` but the cluster has `6`, the misalignment between the desired manifest and the runtime state is confirmed.

### How to fix (during a maintenance window)

<ol type="1">
<li>Confirm the target context before making any change:

   ```bash
   kubectl config current-context
   ```</li>
<li>Back up the current StatefulSet (optional, recommended):

   ```bash
   kubectl get statefulset plantsuite-redis -n redis -o yaml > /tmp/redis-sts-backup.yaml
   ```</li>
<li>Delete the old StatefulSet. <strong>Note</strong>: the bound PVCs are <strong>NOT</strong> touched by this operation; the Redis data is preserved.

   ```bash
   kubectl delete statefulset plantsuite-redis -n redis
   ```</li>
<li>Apply the demo overlay (which renders `replicas: 1`):

   ```bash
   kubectl apply -k k8s/overlays/demo/redis/
   ```</li>
<li>Watch the Pod come up:

   ```bash
   kubectl get pods -n redis -l app=redis -w
   ```

   Wait until `plantsuite-redis-0` reaches `1/1 Running` (Ready).</li>
</ol>

### Post-remediation (validation)

Confirm the detected replica count is back to `1`:

```bash
kubectl logs plantsuite-redis-0 -c get-replicas -n redis
```

It should show `Detected 1 replicas`.

Confirm the execution mode change:

```bash
kubectl logs plantsuite-redis-0 -c redis -n redis --tail=20
```

It should show `Running mode=standalone`.

Confirm the Pod state:

```bash
kubectl get pod plantsuite-redis-0 -n redis
```

It should show `1/1 Running` with `READY 1/1`.

### Notes

- **PVCs persist after `delete statefulset`**: the volumes (`data-plantsuite-redis-0`) are not removed by deleting the StatefulSet, so the Redis data is kept. Remove the PVC explicitly only if you want to wipe the Redis state:
  ```bash
  kubectl delete pvc data-plantsuite-redis-0 -n redis
  ```
- **`kubectl apply -k` without delete may not converge** from `replicas=6` to `replicas=1` because the Kubernetes 3-way merge preserves the runtime `replicas` field. The `delete` + `apply -k` flow is safer to correct the misalignment.
- **Branch-aware readinessProbe (preventive hardening)**: the `readinessProbe` in `k8s/base/redis/statefulset.yaml` (lines 201-219) has been adjusted to distinguish `standalone` mode (`REPLICAS=1`) from `cluster` mode (`REPLICAS>1`), avoiding false-negative readiness in demo environments. This change is a hardening improvement and <strong>does not resolve</strong> the operational incident described above — the root cause is the misalignment between the applied overlay and the runtime state. The decision is recorded in `wiki/decisions/redis-readiness-probe-branch-aware.md` and the probe convention in `wiki/conventions/probes.md`.

## Notes

- **Ping fails but HTTPS works**: in clusters running MetalLB in L2 mode, the LoadBalancer VIP does not respond to ICMP. Use `curl` or `openssl s_client` instead of `ping` to validate access.
- **Full list of hosts**: see the "Acesso aos Serviços" / "Service Access" section of the `README.md` at the repository root.
- **PVCs persist after StatefulSet deletion**: when deleting a StatefulSet (e.g., Redis), the bound PVCs are not removed automatically — the data is preserved. Remove the PVCs explicitly only if you want to wipe the state.
