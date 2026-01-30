# Kubernetes with Kind: Local Testing Guide

## What is Kind?

[Kind (Kubernetes IN Docker)](https://kind.sigs.k8s.io/) is an open source tool that lets you create Kubernetes clusters locally using Docker or Podman containers as cluster nodes. The main goal of Kind is to make it easy to develop, test, and CI/CD Kubernetes applications and configurations in controlled, disposable environments, without the need for cloud infrastructure or heavy VMs.

### Advantages of Kind
- **Fast and lightweight**: Clusters are created in minutes using containers.
- **Isolated environment**: Ideal for testing, development, and CI/CD.
- **Compatibility**: Works with both Docker and Podman.
- **Easy to discard**: Clusters can be quickly removed after use.

## Requirements
- [Docker](https://docs.docker.com/get-docker/) **or** [Podman](https://podman.io/getting-started/installation)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/)

## Creating a single-node cluster (ideal for minimal overlay tests)

```bash
kind create cluster --name minimal
```

This command creates a cluster with only one node (control-plane), enough for quick tests and validation of the `minimal` overlay. No config file is needed, as this is Kind's default behavior.

## Creating a 3-node cluster (1 control-plane + 2 workers)

Ideal for testing scenarios closer to production, such as the `base` and `production` overlays.

```bash
kind create cluster --name multi-node --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
```

## Enabling Load Balancer with cloud-provider-kind

By default, Kind does not natively support LoadBalancer Services. To simulate this feature in development environments, use [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind):

1. Follow the instructions in the official repo: [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind?tab=readme-ov-file#install)
2. Install the provider in the created Kind cluster.
3. After installation, you can create `LoadBalancer` services and get simulated external IPs.

---

## Known issues

If you have problems with your environment, see the [Known Issues](https://kind.sigs.k8s.io/docs/user/known-issues/) guide for Kind.

## References
- [Kind - Official Site](https://kind.sigs.k8s.io/)
- [Kind - Documentation](https://kind.sigs.k8s.io/docs/)
- [cloud-provider-kind](https://github.com/aojea/cloud-provider-kind)
- [Docker](https://docs.docker.com/get-docker/)
- [Podman](https://podman.io/)
