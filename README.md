# SampleGrpcProject

A GitHub template repository for new services: run `make init` and you get a Go-based gRPC service, a PostgreSQL database, an HTTP-to-gRPC gateway using Kong, Google sign-in via JWT, and a React web front-end, all running on a self-hosted Kubernetes cluster exposed via a Cloudflare tunnel.

## Architecture

```
  HTTPS (public)          HTTP/NodePort (LAN)
       │                         │
       ▼                         │
┌─────────────────┐              │
│  Cloudflare     │              │
│  Tunnel         │              │
└────────┬────────┘              │
         │                       │
         ▼                       ▼
  ┌──────────────────────────────────────┐
  │         k8s Cluster (grpc-demo ns)   │
  │                                      │
  │  ┌────────────────────────────────┐  │
  │  │  greeter-web (Nginx)           │  │◀── :30090
  │  │  · serves React SPA            │  │
  │  │  · proxies /greeter/* to Kong  │  │
  │  └───────────────┬────────────────┘  │
  │                  │ HTTP/JSON         │
  │                  ▼                   │
  │  ┌────────────────────────────────┐  │
  │  │  Kong API Gateway              │  │◀── :30080
  │  │  · grpc-gateway plugin         │  │
  │  │  · HTTP/JSON ↔ gRPC            │  │
  │  │  · strip-path: false           │  │
  │  └───────────────┬────────────────┘  │
  │                  │ gRPC              │
  │                  ▼                   │
  │  ┌────────────────────────────────┐  │
  │  │  greeter (Go gRPC)             │  │◀── :30051
  │  │  · Echo (anonymous)            │  │
  │  │  · AuthService (Google + JWT)  │  │
  │  │  · auth interceptor on every   │  │
  │  │    non-public RPC              │  │
  │  └───────────────┬────────────────┘  │
  │                  │                   │
  │                  ▼                   │
  │  ┌────────────────────────────────┐  │
  │  │  PostgreSQL (CNPG)             │  │
  │  │  · echo_requests               │  │
  │  │  · users                       │  │
  │  └────────────────────────────────┘  │
  └──────────────────────────────────────┘
```

**Public URL:** `https://grpc-demo.latentlab.cc` (via the shared Cloudflare tunnel → `greeter-service` ClusterIP, configured by `k8s/tunnelroute.yaml`)

**LAN access:**

| Service       | Address                       |
|---------------|-------------------------------|
| Web UI        | `http://<node-ip>:30090`      |
| Kong proxy    | `http://<node-ip>:30080`      |
| gRPC direct   | `<node-ip>:30051`             |

## Repository Layout

```
SampleGrpcProject/
├── project.yaml             # Single source of truth for all project-specific config
├── CLAUDE.md                # Project conventions for Claude Code sessions
├── proto/                   # Protobuf definitions (source of truth for service contracts)
│   ├── greeter.proto        # Greeter service + imports auth.proto (umbrella for Kong)
│   └── auth.proto           # AuthService — Google login, /me, ListUsers
├── pb/                      # Generated Go gRPC stubs (committed)
├── internal/
│   ├── auth/                # JWT issue/validate, Google ID-token verify, interceptor
│   ├── db/                  # GORM DB layer (EchoRequest + User models)
│   └── logger/              # slog-based JSON logger
├── cmd/loadtest/            # gRPC load-test tool
├── web/                     # React + TypeScript front-end (see web/README.md)
│   ├── src/
│   │   ├── api/auth.ts      # Fetch wrappers for /greeter/api/auth/*
│   │   ├── auth/            # AuthContext, AuthBar, useAuth() hook
│   │   └── generated/       # ts-proto output (committed)
├── k8s/
│   ├── templates/           # Parameterized manifest templates (envsubst variables)
│   └── *.yaml               # Generated manifests — run `make generate-k8s` to refresh
├── .github/workflows/       # CI workflow (ci.yml.disabled until `make init`)
├── .github/actions/         # reclaim-dind: bounded Docker cleanup on the shared runner
├── .githooks/               # Pre-commit hook (`make hooks-install` to enable)
├── scripts/                 # init-project.sh (template rename) + admin token mint
├── main.go                  # gRPC server entry point (interceptor + service registration)
├── Makefile
├── .golangci.yml            # Linter config
└── VERSION                  # Semver source of truth
```

## Endpoints

Kong exposes the gRPC services via HTTP/JSON transcoding under the `/greeter/api` prefix:

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/greeter/api/echo` | public | Echo a message; persists to `echo_requests` |
| `POST` | `/greeter/api/auth/login` | public | Exchange a Google ID token for a session JWT |
| `GET`  | `/greeter/api/auth/me` | bearer JWT | Return the authenticated user's profile |
| `POST` | `/greeter/api/auth/me` | bearer JWT | Update the user's username |
| `GET`  | `/greeter/api/admin/users` | admin JWT | List all users |

Kong runs with `strip-path: "false"` — the backend sees the full path. Every proto `google.api.http` annotation must include the `/greeter/api` prefix; `make check-api-paths` enforces this.

```bash
# Anonymous Echo
curl -X POST https://grpc-demo.latentlab.cc/greeter/api/echo \
  -H 'Content-Type: application/json' \
  -d '{"message": "hello"}'

# Auth'd ListUsers (mint a short-lived admin token from the cluster secret)
ADMIN_JWT=$(scripts/mint-cluster-token.sh)
curl -H "Authorization: Bearer $ADMIN_JWT" \
  https://grpc-demo.latentlab.cc/greeter/api/admin/users

# Direct gRPC
grpcurl -plaintext -d '{"message": "hello"}' <node-ip>:30051 greeter.Greeter/Echo
```

## Auth Flow

The frontend obtains a Google ID token via `@react-oauth/google` and posts it to `/greeter/api/auth/login`. The server verifies the token against Google's JWKS, upserts a `users` row keyed by the Google `sub`, and returns a 24-hour HS256 session JWT. The frontend stores the JWT in `localStorage` and attaches `Authorization: Bearer <jwt>` to every subsequent request.

The unary gRPC interceptor in `internal/auth/interceptor.go` enforces:
- `publicRPCs` — `Echo`, `LoginWithGoogle`, gRPC health checks, reflection: no JWT required
- `adminRPCs` — `ListUsers`: requires `is_admin = true` in the JWT
- Everything else — requires a valid session JWT

To make a user an admin, flip the bit in the database directly:

```bash
make db-cleanup   # or psql in by hand
kubectl exec -n grpc-demo \
  $(kubectl get pod -n grpc-demo -l cnpg.io/cluster=greeter-db -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U greeter -c "UPDATE users SET is_admin = true WHERE email = '<their-email>';"
```

Required env vars (read from the `greeter-auth` k8s secret — see `k8s/README.md` step 6):

| Var | Purpose |
|-----|---------|
| `GOOGLE_CLIENT_ID` | OAuth 2.0 client ID; validated against the `aud` claim on Google ID tokens |
| `JWT_SECRET` | HMAC-SHA256 key signing session JWTs. Generate once with `openssl rand -base64 48` and persist. |
| `GOOGLE_JWKS_URL` | (optional) Override the JWKS endpoint — defaults to Google production |

## Stack

| Layer | Technology |
|-------|------------|
| Front-end | React 19 + TypeScript, Vite, Nginx, @react-oauth/google |
| API Gateway | Kong (grpc-gateway plugin, HTTP/JSON ↔ gRPC) |
| gRPC Service | Go 1.25, GORM, CloudNativePG, golang-jwt/v5 |
| Database | PostgreSQL via CNPG operator on k8s |
| Cluster | k8s (multi-node, self-hosted) |
| Tunnel | Shared Cloudflare tunnel via [Cloudflare-Tunnel-Operator](https://github.com/CallMeCCLemon/Cloudflare-Tunnel-Operator) (`TunnelRoute`) |
| CI | GitHub Actions on the shared org self-hosted DinD runner |

## Shared platform

Every project built from this template is a **tenant** of one shared cluster platform. These pieces exist once per cluster and are owned by the platform repo (currently [RiftboundEngine](https://github.com/latentlab-cc/Riftbound-Engine)), not by this repo:

| Shared piece | Where it lives in the platform repo |
|---|---|
| Kong Helm release + `kong-values.yaml` (proto mounts for every project) | `k8s/templates/kong-values.yaml`, `make kong-deploy` |
| Container registry (`registry-system`, NodePort 32000) + registry GC | `k8s/registry.yaml`, `scripts/setup-registry.sh`, `make registry-prune` |
| Org-wide self-hosted GitHub Actions runner (`self-hosted, k8s`) | `k8s/runner.yaml`, `docker/runner/` |
| CNPG operator | `scripts/install-cnpg.sh` |
| MinIO (object storage) | `k8s/minio-values.yaml` |

The Cloudflare tunnel is shared too: one `ClusterTunnel` (`home`, from `tunnel_name` in `project.yaml`) run by [Cloudflare-Tunnel-Operator](https://github.com/CallMeCCLemon/Cloudflare-Tunnel-Operator), with its own 2 cloudflared replicas. Projects attach to it with a `TunnelRoute`.

A project only owns its own namespace, Deployments, Postgres cluster, `TunnelRoute`, its `<project>-proto` configmap, and its host-scoped Kong Ingress. `make kong-deploy` here never runs `helm upgrade kong`: doing that from a project overwrote other projects' proto mounts.

## Starting a new project

### 1. Create the repo from the template

On GitHub: **Use this template → Create a new repository**, owner **latentlab-cc** (the shared runner only serves repos in that org). Or from the CLI:

```bash
gh repo create latentlab-cc/<Repo> --template CallMeCCLemon/SampleGrpcService --private --clone
cd <Repo>
```

### 2. Rename everything

```bash
make init NAME=<project_name> REPO=https://github.com/latentlab-cc/<Repo>
# optional: MODULE=<go module path>  (defaults to github.com/latentlab-cc/<Repo>)
```

`NAME` is lowercase with no hyphens. It becomes the k8s names, namespace, DB name, proto package, the `/<name>/api` prefix, and `<name>.latentlab.cc`. `make init`:

- rewrites `project.yaml` (picks free grpc/web NodePorts from the cluster when `kubectl` can reach it),
- renames `proto/greeter.proto`, the `Greeter` service, and the Go module across the repo,
- regenerates `pb/`, `web/src/generated/`, `k8s/*.yaml`, and `web/.env`,
- enables CI (`ci.yml.disabled` → `ci.yml`) and resets `VERSION` to `0.1.0`.

Then `make build && make test`, review `git status`, commit, and `make hooks-install`. Don't push yet: once CI is enabled, a push to `main` deploys.

### 3. Register with the shared platform

```bash
make kong-register   # prints the kong-values.yaml block for this project
```

Paste that block into the platform repo's `k8s/templates/kong-values.yaml`, then from the platform repo run `make generate-k8s && make kong-deploy` once. The volume is `optional: true`, so the gateway still starts before this project's configmap exists.

### 4. First deploy

One-time, from your machine (see [`k8s/README.md`](k8s/README.md) for detail):

```bash
make deploy-all                      # namespace, deployments, postgres, Kong ingress, TunnelRoute
kubectl create secret generic <name>-auth -n <name> \
  --from-literal=google-client-id="<id>.apps.googleusercontent.com" \
  --from-literal=jwt-secret="$(openssl rand -base64 48)"
make kong-deploy                     # proto configmap + Kong restart
kubectl -n <name> get tunnelroute    # READY=True once the hostname is live
```

The `TunnelRoute` publishes `public_domain` through the shared tunnel and creates its DNS record. If the hostname already has a DNS record from an older setup, set `tunnel_adopt_dns: true` in `project.yaml` for the first deploy.

Set `google_client_id` in `project.yaml` (then `make generate-k8s`) once you've created the OAuth client. Then push to `main`: CI tests, builds both images, rolls them out with `make k8s-rollout`, prunes old tags, and refreshes the Kong routes.

### GitHub setup

What `gh` can't do, and how to do it on github.com:

| Setting | Where | Why |
|---|---|---|
| Runner group access | latentlab-cc → Settings → Actions → Runner groups → Default → Repository access | Must be **All repositories**, or add each new repo. If any project repo is public, also tick **Allow public repositories**. |
| Branch protection on `main` (optional) | Repo → Settings → Rules → Rulesets | Require the **Tests + Coverage** and **Integration tests** checks. |

## Make Targets

Run `make help` for the full list. The main ones:

| Target | Purpose |
|---|---|
| `make init NAME=… REPO=…` | Turn a fresh copy of the template into a new project |
| `make` / `make all` | Regenerate proto + build Go binary |
| `make build` | Compile `bin/server` and every package |
| `make proto` / `make web-proto` | Regenerate Go / TypeScript gRPC stubs |
| `make check-api-paths` | Verify proto annotations include `api_prefix` |
| `make test` | Fast Go tests (sqlmock + interceptor matrix, no Docker) |
| `make test-integration` | Integration-tagged tests only (Docker; `VERBOSE=1` for `-v`) |
| `make vet-integration` | Type-check integration-tagged tests without Docker |
| `make lint` / `lint-new` / `lint-fix` | golangci-lint (installs via brew, or `go install` on CI) |
| `make web-build` / `make web-lint` | Frontend build (tsc + vite) / eslint |
| `make coverage-go` / `coverage-check` | Coverage report / enforce floors from project.yaml |
| `make docker-build` / `web-docker-build` | Buildx multi-arch build + push (`:VERSION-SHA` and `:latest`) |
| `make k8s-rollout` | `kubectl set image` both deployments to the current SHA tag and wait |
| `make release` | Both image builds in parallel, then `k8s-rollout` |
| `make deploy` / `web-deploy` / `deploy-all` | `kubectl apply` the manifests (bootstrap only) |
| `make kong-deploy` | Refresh this project's proto configmap + Ingress; restart Kong only if protos changed |
| `make kong-register` | Print the platform `kong-values.yaml` block for this project |
| `make generate-k8s` | Render `k8s/templates/*.yaml` → `k8s/*.yaml` and `web/.env` |
| `make registry-show` / `registry-prune` | List tags / delete this project's stale tags (digest-safe, no GC) |
| `make hooks-install` | Point git at `.githooks/` for the pre-commit hook |
| `make loadtest` / `db-cleanup` | Load test / truncate `echo_requests` |

Never call `go`, `protoc`, `golangci-lint`, or `kubectl` directly — use the targets. See `CLAUDE.md` for the rationale.

## Protobuf Workflow

The proto file is the **source of truth** for all service contracts. After any change:

```bash
make proto              # rebuilds pb/ (Go)
make web-proto          # rebuilds web/src/generated/ (TypeScript)
make check-api-paths    # enforce api_prefix on every annotation
make web-build          # verify TypeScript compiles
make test
```

Pushing to `main` then rebuilds, rolls out, and runs `make kong-deploy`, which restarts Kong only if a proto actually changed.

> Generated stubs in `pb/` and `web/src/generated/` are committed. A failing `make web-build` after `make web-proto` means a breaking proto change that requires updates to the web app before it can be deployed.

Kong's grpc-gateway plugin has constraints the Go grpc-gateway doesn't; read [`k8s/README.md` → Kong gateway constraints](k8s/README.md#kong-gateway-constraints) before adding HTTP routes.

## Development

```bash
make hooks-install      # one-time per clone: lint, build, vet-integration, and web checks before each commit
make                    # regen proto + build server
make test               # fast tests
make lint               # full lint
make run                # run gRPC server locally (requires DATABASE_URL)
cd web && npm run dev   # web dev server; proxies /greeter/* to Kong with Host set to public_domain
```

## CI

`.github/workflows/ci.yml.disabled` is dormant in the template so the template repo never deploys. `make init` enables it. It runs on the shared org runner (`runs-on: [self-hosted, k8s]`):

- **Tests + Coverage** and **Integration tests** on every PR and push
- on `main`: **Docker Build (backend)** and **(web)** in parallel → **K8s Rollout** (gated on all four; also prunes stale tags) → **Deploy Kong routes**
- every Docker-using job ends with `.github/actions/reclaim-dind` so the runner pod's capped DinD disk doesn't fill and get the pod evicted
