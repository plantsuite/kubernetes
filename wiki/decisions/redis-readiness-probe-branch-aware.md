# ADR: Redis Readiness Probe — Branch-Aware (Standalone vs Cluster)

## Status: Accepted

## Context
The Redis StatefulSet runs as 1 replica (standalone) in the demo overlay and 6 replicas (cluster) in base/production. `init-cluster.sh` is adaptive (exits 0 when `REPLICAS<=1`, sets `cluster-enabled no`), but the readiness probe previously ran `redis-cli cluster info`/`cluster nodes` unconditionally. In standalone mode those commands fail, so a Pod can run but remain `NotReady (0/1)` while liveness continues to pass with `PING`; the root cause was a mode-fixed probe, not the init script.

## Decision
Make the readiness probe branch-aware on `REPLICAS` (sourced from `/shared/replicas.env`, defaulting to 6):
- `REPLICAS==1` (standalone): `redis-cli ping` **and** `redis-cli info server | grep -q 'redis_mode:standalone'`
- `REPLICAS>1` (cluster): `cluster_state:ok` **and** membership (`myself.*master|myself.*slave`) **and** `cluster_size>=2`

Additional decisions:
- Use POSIX `grep -o 'cluster_size:[0-9][0-9]*' | cut -d: -f2 | head -n1` instead of `grep -oP` (PCRE) for portability across GNU grep and busybox/alpine.
- Fail-closed: no `|| echo 3` fallback that would mask an incomplete cluster as ready.
- Multi-node deployments use `Parallel` StatefulSet pod management because pod 0 discovers peers before any pod can become ready; ordered readiness would deadlock bootstrap.
- The headless peer Service sets `publishNotReadyAddresses: true` so DNS discovery exposes those peers before readiness succeeds.
- A fresh six-node cluster must create 3 masters and assign one replica to each: node 3 to master 0, node 4 to master 1, and node 5 to master 2. Bootstrap must propagate assignment and verification failures rather than suppress them, and POSIX shell nested loops must use isolated variable names to avoid clobbering outer-loop state.
- Changing `podManagementPolicy` is an immutable StatefulSet change and requires the Redis-specific safe migration in `tools/lib/k8s-adapter.sh`, not an in-place patch. The migration fails closed if retention or PVC discovery cannot be verified, retains and verifies the Redis PVCs before recreating the controller, and accepts brief Redis downtime while the controller is recreated.
- Live Colima validation in a disposable namespace using `emptyDir` storage confirmed that six nodes on one host complete bootstrap, readiness, slot assignment, and the intended 3-master/3-replica HA topology. The scratch namespace was cleaned up afterward. No scheduling restriction required relaxation; the standalone demo and its PVCs remained untouched. This validates fresh bootstrap only, not restart or failure durability.

References: `k8s/base/redis/statefulset.yaml`, `k8s/base/redis/service-nodes.yaml`, `config/init-cluster.sh`, and `tools/lib/k8s-adapter.sh`.

## Consequences
- One probe definition serves both standalone and cluster overlays; no per-overlay probe patch needed.
- Probe logic must stay in sync with `init-cluster.sh`'s mode detection (both key off `REPLICAS`).
- General rule: when a StatefulSet supports both standalone (1 replica) and cluster (>1), probes must branch by mode — adaptive init scripts alone are insufficient if the probe assumes a fixed mode.
- Slightly more complex probe command; trade-off accepted to avoid silent NotReady pods.
- A rollout that changes Redis pod management is a planned migration, not a routine StatefulSet update. PVC retention and identity must be protected before controller recreation.
- Cluster bootstrap now depends on pre-readiness peer DNS, explicit error propagation, and stable shell loop state; retain those properties when changing discovery or topology logic.
