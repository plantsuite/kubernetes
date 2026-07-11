# Secret Management

## Pattern
1. `.env.secret` files contain environment variables
2. `secretGenerator` in `kustomization.yaml` reads from `.env.secret`
3. `disableNameSuffixHash: true` — stable names, no hash suffix
4. Secrets mounted via `envFrom: secretRef` in containers

## Files
| File | Secret Name | Type |
|------|-------------|------|
| `.env.secret` | `plantsuite-env` | Opaque |
| `dockerconfig.json` | `plantsuite-cr` | kubernetes.io/dockerconfigjson |
| `license.crt` | `plantsuite-license` | Opaque (file mount) |

## DB Password Pre-generation

DB operators (Percona MongoDB, Percona PostgreSQL) are configured to **reuse a pre-existing Secret** rather than auto-generate passwords. The installer fills `.env.secret` templates with `generate_secure_password` *before* applying the CR, so the operator finds the Secret already present and adopts it.

**Why pre-generate:** deterministic, operator-independent credentials; same secret-generator toolchain as the rest of the stack; secrets exist before the CR reconcile starts, avoiding a race where the operator generates a password the rest of the platform never learns.

### MongoDB (PSMDB)
- Template: `k8s/base/mongodb/plantsuite-psmdb/.env.secret` — 10 keys:
  - 5 static Percona usernames: `MONGODB_{DATABASE_ADMIN,CLUSTER_ADMIN,CLUSTER_MONITOR,USER_ADMIN,BACKUP}_USER`
  - 5 empty password templates: matching `*_PASSWORD=`
- `secretGenerator` → Secret `plantsuite-psmdb-secrets` (matches CR `spec.secrets.users: plantsuite-psmdb-secrets`)
- Operator reuses the pre-existing Secret instead of creating its own.

### PostgreSQL (PPGO / CrunchyData PGO)
- 3 templates in `k8s/base/postgresql/plantsuite-ppgc/`, each with **only** `password=`:
  - `.env-postgres.secret`, `.env-keycloak.secret`, `.env-vernemq.secret`
- 3 `secretGenerator` entries → Secrets `plantsuite-ppgc-pguser-{postgres,keycloak,vernemq}`
- Naming follows PGO default: `<cluster>-pguser-<user>`. Operator auto-detects and reuses; only the `password` key is required — PGO derives the SCRAM verifier and populates `user`, `uri`, etc.

### Installer hook (`k8s-adapter.sh`)
- `mongodb-instance`: 5 `generate_secure_password` calls (one per `*_PASSWORD` key) before `real_apply_component`
- `postgresql-instance`: 3 `generate_secure_password` calls (one per `.env-*.secret` file) before `real_apply_component`
- Mirrors the existing `redis` component (1 call to `k8s/base/redis/.env.secret`).
- `generate_secure_password` uses `set_env_value` (non-destructive upsert) → multiple calls accumulate keys in one file; idempotent across re-runs.

## Tracking (not gitignored)

`.env.secret`, `dockerconfig.json`, and `license.crt` are **tracked in git as empty/placeholder templates** — they are NOT gitignored. The installer fills them at runtime via `set_env_value` / `generate_secure_password`. This keeps templates reviewable and the tree self-describing; real secret material never enters git.

## Management Script
- `tools/lib/secrets.sh` — AWK-based file manipulation
- `set_env_value()` / `get_env_value()` — read/write .env.secret
- `get_k8s_secret_value()` — read from existing K8s secrets (base64)
- `sanitize_env_file()` — remove invalid keys
- `generate_secure_password()` — upsert a random password into a given `.env.secret` key
- Idempotent: safe to run multiple times
