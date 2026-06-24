# Wiki Index

Workspace knowledge base for the PlantSuite Kubernetes deployment stack.

## Architecture
- [System Overview](architecture.md) — component map, namespaces, dependencies

## Conventions
- [Naming](conventions/naming.md) — resource names, image tags, selectors
- [Secrets](conventions/secrets.md) — .env.secret, secretGenerator, docker config
- [TLS & Certificates](conventions/tls-certificates.md) — cert-manager, issuers, extraction
- [Resources](conventions/resources.md) — requests, limits, HPA, PDB, topology
- [Probes](conventions/probes.md) — startup, readiness, liveness patterns
- [Labels](conventions/labels.md) — standard labels, selectors, matching
- [Markdown / GitHub](conventions/markdown-github.md) — comportamento do GitHub com numeração

## Domain
- [PlantSuite Services](domain/plantsuite-services.md) — 17 microservices, images, ports
- [Infrastructure](domain/infrastructure.md) — databases, messaging, operators
- [Istio Mesh](domain/istio-mesh.md) — ambient mode, gateway, VirtualServices
- [Installer](domain/installer.md) — TUI workflow, pipeline phases, screens

## Decisions
- [Kustomize Base+Overlays](decisions/kustomize-base-overlays.md) — why overlay pattern
- [Istio Ambient Mode](decisions/istio-ambient-mode.md) — why no sidecar
- [Percona Operators](decisions/percona-operators.md) — why Percona for DBs
- [Self-Signed Certificates](decisions/self-signed-certificates.md) — why self-signed issuer
- [Redis Readiness Probe — Branch-Aware](decisions/redis-readiness-probe-branch-aware.md) — standalone vs cluster probe branching
- [Ordered Lists in GitHub Bullets](decisions/ordered-lists-github-roman.md) — type="1" for decimal, roman numerals, GitHub rendering

## Skill Candidates
- [Kustomize Overlay Creation](skill-candidates/kustomize-overlay-creation.md) — adding new environments
