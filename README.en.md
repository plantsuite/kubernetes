# PlantSuite Kubernetes

[Português (pt)](README.md) | [English (en)](README.en.md)

## Overview

[Kustomize](https://kustomize.io/) manifests to install, update, and remove the [PlantSuite](https://www.plantsuite.com) stack on Kubernetes, with overlays for different scenarios (base, demo, production). Includes automated scripts, dependency configuration, certificates, and instructions for secure service access.

> **Important**: These manifests serve as a **reference template**. You will likely need to adjust them according to your environment's specific needs, such as: PVC sizes, resource limits, network configurations, backup strategies, security policies, and integrations with existing systems.

> 📚 For detailed guides on customization, observability, and other topics, see the [docs folder](docs/).

## Layers
- **base** (k8s/base): HA with lean resources; good for production-like testing with less hardware.
- **demo** (k8s/overlays/demo): aggressive profile for demos/labs; 1 replica and broad removal of CPU/memory requests/limits.
- **production** (k8s/overlays/production): starting point for production; adjust as needed for traffic/SLAs.

## Suggested cluster sizing

| Overlay     | Nodes | vCPU | RAM  | Disk  |   | **Total vCPU** | **Total RAM** | **Total Disk** |
|-------------|-------|------|------|--------|---|----------------|---------------|----------------|
| demo        | 1     | 4    | 16Gi | 150Gi  |   | **4**          | **16Gi**      | **150Gi**      |
| base        | 3     | 4    | 16Gi | 200Gi  |   | **12**         | **48Gi**      | **600Gi**      |
| production  | 3     | 8    | 32Gi | 500Gi  |   | **24**         | **96Gi**      | **1500Gi**     |

Values in vCPU/RAM/Disk are per node; bold columns indicate cluster totals. These are minimum recommendations; adjust CPU/Mem/PVCs as needed for observed traffic, data, and SLOs.

## Installation and Uninstallation

### Installed Components

The PlantSuite stack consists of the following components, organized by category:

| Category | Component | Description |
|----------|-----------|-------------|
| **Databases** | MongoDB | NoSQL database for unstructured data and timeseries |
| | PostgreSQL | Relational database for transactional data |
| | Redis | In-memory storage for cache and queues |
| **Messaging** | RabbitMQ | Message broker for asynchronous communication between services |
| | VerneMQ | MQTT broker for IoT device communication |
| **Infrastructure** | Istio | Service mesh for traffic management, security, and observability |
| | Cert-Manager | Automatic SSL/TLS certificate management |
| | Metrics Server | Kubernetes cluster resource metrics collection |
| **Authentication** | Keycloak | Identity and access management (IAM) |
| **Observability** | Aspire Dashboard | Distributed observability dashboard for .NET |
| **Applications** | PlantSuite Portal | Main PlantSuite web interface |
| | PlantSuite APIs | Microservices (Devices, Entities, Queries, Tenants, Dashboards, Notifications, Alarms, SPC, Timeseries, Workflows) |
| | PlantSuite Gateway | IoT Gateway for OPC-UA/MQTT data acquisition. Can be installed standalone without databases (uses SQLite + local auth). |

### Prerequisites

Before installing, you must **obtain the `license.crt` license file** and **the access credentials for the `plantsuite.azurecr.io` registry**.

Request both from PlantSuite support at [https://support.plantsuite.com](https://support.plantsuite.com).

The license file should be placed at `k8s/base/plantsuite/license.crt` and the credentials (username and password) should be entered in `k8s/base/plantsuite/dockerconfig.json` and `k8s/base/vernemq/dockerconfig.json`.

In addition to the above files, ensure the following tools are installed and available in your `PATH`:

- `kubectl`: required to interact with the Kubernetes cluster and set the desired context. Official installation instructions: https://kubernetes.io/docs/tasks/tools/
- `helm`: required for using `--enable-helm` with `kubectl kustomize` — make sure you are using a compatible version, currently version 3. Official installation instructions: https://helm.sh/docs/intro/install/

### Tools

- **Install**: `./tools/install.sh`
	- Applies the stack in the correct order, waits for service readiness, and fills in required secrets/configs.
	- Usage: run from the root, choose the overlay (base/demo/production), and confirm with `yes`.
- **Uninstall**: `./tools/uninstall.sh`
	- Removes everything in reverse order and waits for safe resource cleanup.
	- Usage: run from the root and confirm with `yes`.

Notes:
- You need `kubectl` configured for the desired context.
- If the stack is already installed, the install script enters update mode to reapply specific components.

## Service Access

After installation, services are exposed via Istio Gateway with the following domains:

### HTTP/HTTPS URLs
- **Gateway API**: `gateway.plantsuite.local`
- **Gateway UI**: `gateway-ui.plantsuite.local`
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

**MQTT Services**
- **VerneMQ (MQTT)**: `mqtt.plantsuite.local` (ports 1883/8883)
- **VerneMQ WebSocket**: `mqtt.plantsuite.local/mqtt`

### Get the Istio Ingress Gateway IP

```bash
kubectl get svc -n istio-ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

If using a local cluster (kind, minikube, etc.) without LoadBalancer, use NodePort:

```bash
kubectl get svc -n istio-ingress gateway
```

### Configure Local DNS

Add entries to the `/etc/hosts` file (Linux/macOS) or `C:\Windows\System32\drivers\etc\hosts` (Windows), replacing `<INGRESS_IP>` with the IP obtained above:

```
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

### Trust the SSL Certificate

Certificates are generated automatically by [cert-manager](https://cert-manager.io) using a self-signed ClusterIssuer. To access services via HTTPS without security errors, you need to extract the CA certificate and add it as trusted:

**Extract the CA certificate:**
```bash
kubectl get secret plantsuite-wildcard-cert -n istio-ingress -o jsonpath='{.data.ca\.crt}' | base64 -d > plantsuite-ca.crt
```

**Import into browser/system:**

- **Linux (Chrome, Chromium, Edge)**: These browsers use the operating system's trust store.
  <ol>
  <li>Copy the certificate and update the trust store:
     ```bash
     sudo cp plantsuite-ca.crt /usr/local/share/ca-certificates/plantsuite-ca.crt
     sudo update-ca-certificates
     ```
     Confirm with `1 added, 0 removed; done.`.</li>
  <li>Close and reopen the browser.</li>
  </ol>

- **macOS**:
  <ol>
  <li>Open `plantsuite-ca.crt`.</li>
  <li>Add it to Keychain Access, marking it as "Always trust".</li>
  </ol>

- **Windows (Chrome, Edge)**:
  <ol>
  <li>Double-click the `plantsuite-ca.crt` file.</li>
  <li>Click "Install Certificate...".</li>
  <li>Choose "Local Machine" (requires administrator) → Next.</li>
  <li>Choose "Place all certificates in the following store".</li>
  <li>Click "Browse" and select "Trusted Root Certification Authorities".</li>
  <li>Next → Finish. Confirm the security warning with "Yes".</li>
  <li>Close and reopen the browser.</li>
  </ol>

- **Firefox (any OS)**: Firefox maintains its own certificate store, separate from the system.
  <ol>
  <li>Open Firefox and type `about:preferences` in the address bar.</li>
  <li>Go to "Privacy & Security" → "Certificates" → "View Certificates".</li>
  <li>In the "Authorities" tab, click "Import".</li>
  <li>Select the `plantsuite-ca.crt` file.</li>
  <li>Check "Trust this CA to identify websites" and click OK.</li>
  </ol>

> **Production environment**: in production, configure a valid certificate on the network (e.g., Let's Encrypt or corporate CA) so that browsers trust the certificate without needing manual import on each machine. This manual import step is only required for demonstration/staging environments.

After configuring, access the services directly via browser or API tools:
- Portal: `https://portal.plantsuite.local`
- Keycloak Admin: `https://account.plantsuite.local`
- Aspire Dashboard: `https://aspire-dashboard.plantsuite.local`
