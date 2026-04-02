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
- **Portal**: `portal.plantsuite.local`
- **Keycloak**: `account.plantsuite.local`
- **Aspire Dashboard**: `aspire-dashboard.plantsuite.local`
- **API Devices**: `devices.plantsuite.local`
- **API Entities**: `entities.plantsuite.local`
