# Kustomize Usage Guide for PlantSuite

## Project Structure

The repository is organized to facilitate the use of [Kustomize](https://kustomize.io/) with different environments and customizations:

`k8s/base/`: Contains the base manifests, with lean, HA-oriented configurations.
`k8s/overlays/`: Overlays for different scenarios:
  - `minimal/`: For labs and demos, 1 replica.
  - `base/`: Lean HA, close to production.
  - `production/`: Starting point for production, adjust as needed.

Each overlay can customize resources, replicas, environment variables, and other parameters without changing the base files.

## How to adjust resource values

To modify values such as CPU, memory, replicas, or other settings:

> 💡 **Tip:** Check the existing overlays in `k8s/overlays/minimal/` and `k8s/overlays/production/` for practical examples of how to apply patches and customizations.

1. **Never change files in `base/` directly**. Create an overlay in `overlays/` (or use an existing one) for your changes.
2. In the desired overlay, add or edit patches (YAML) to override only the necessary fields. Example based on the `minimal/istio-ingress` overlay:

```yaml
# k8s/overlays/minimal/istio-ingress/patches/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: gateway
spec:
  minReplicas: 1
  maxReplicas: 1
```

And include this patch in the overlay's `kustomization.yaml`:

```yaml
patches:
  - path: patches/hpa.yaml
    target:
      kind: HorizontalPodAutoscaler
      name: gateway
```

### Example of JSON6902 patch (`op: replace`)

To adjust, for example, a container's resources, use a JSON6902 patch based on the `production/istio-ingress` overlay:

```yaml
# k8s/overlays/production/istio-ingress/patches/deployment-ops.yaml
- op: replace
  path: /spec/template/spec/containers/0/resources
  value:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 512Mi
```
