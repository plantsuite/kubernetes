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

1. Obtain the correct gateway IP from the cluster:

   ```bash
   kubectl get svc -n istio-ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```

2. Edit the local hosts file, adding all service entries pointing to that IP:
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
   ```

3. Clear the browser DNS cache (close and reopen the browser, or use `about:networking#dns` → Clear DNS cache in Firefox). On Windows, run `ipconfig /flushdns`.

4. Validate again with `getent hosts portal.plantsuite.local` — the returned IP should be the gateway's.

## 2\. Browser certificate warning ("Your connection is not private")

**Symptom**: the browser displays "Your connection is not private" / `NET::ERR_CERT_AUTHORITY_INVALID` when accessing any `*.plantsuite.local` service over HTTPS.

**Cause**: the cluster uses a self-signed certificate (`selfsigned` ClusterIssuer from cert-manager), which is expected in demonstration/staging environments. The browser does not trust the CA until the certificate is imported manually.

### How to resolve

1. Extract the CA certificate from the cluster:

   ```bash
   kubectl get secret plantsuite-wildcard-cert -n istio-ingress -o jsonpath='{.data.ca\.crt}' | base64 -d > plantsuite-ca.crt
   ```

2. Import the `plantsuite-ca.crt` file into the operating system or browser, as appropriate:

   - **Linux (Chrome, Chromium, Edge)** — use the system trust store:

     ```bash
     sudo cp plantsuite-ca.crt /usr/local/share/ca-certificates/plantsuite-ca.crt
     sudo update-ca-certificates
     ```

     Confirm the output shows `1 added, 0 removed; done.`.

   - **macOS**:
     1\. Open the `plantsuite-ca.crt` file.
     2\. Add it to Keychain Access.
     3\. Set the trust policy to "Always trust".

   - **Windows (Chrome, Edge)**:
     1\. Double-click the `plantsuite-ca.crt` file.
     2\. Click "Install Certificate...".
     3\. Choose "Local Machine" (requires administrator) → Next.
     4\. Choose "Place all certificates in the following store".
     5\. Click "Browse" and select "Trusted Root Certification Authorities".
     6\. Next → Finish. Confirm the security warning with "Yes".

   - **Firefox (any OS)** — maintains its own trust store, separate from the system:
     1\. Open Firefox and type `about:preferences` in the address bar.
     2\. Go to "Privacy & Security" → "Certificates" → "View Certificates".
     3\. On the "Authorities" tab, click "Import".
     4\. Select the `plantsuite-ca.crt` file.
     5\. Check "Trust this CA to identify websites" and click OK.

3. Close and reopen the browser. Access the service again — the padlock should appear without a certificate warning.

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

1. Update the LAN DNS (or the local `/etc/hosts`) so all `*.plantsuite.local` hosts point to the LoadBalancer IP obtained above.

2. If the MetalLB pool is exhausted (only a single `/32` IP already in use by the gateway), expand the pool before provisioning new LoadBalancers. To inspect the current pool:

   ```bash
   kubectl get IPAddressPool -A -o yaml
   ```

## Notes

- **Ping fails but HTTPS works**: in clusters running MetalLB in L2 mode, the LoadBalancer VIP does not respond to ICMP. Use `curl` or `openssl s_client` instead of `ping` to validate access.
- **Full list of hosts**: see the "Acesso aos Serviços" / "Service Access" section of the `README.md` at the repository root.
