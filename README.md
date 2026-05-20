# SampleGrpcProject

A testbed — and reusable template — for wiring together a Go-based gRPC service, a PostgreSQL database, an HTTP-to-gRPC gateway using Kong, Google sign-in via JWT, and a React web front-end, all running on a self-hosted Kubernetes cluster exposed via a Cloudflare tunnel.

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

**Public URL:** `https://grpc-demo.latentlab.cc` (via Cloudflare tunnel → `greeter-service` ClusterIP)

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
│   │   └── optional/        # Opt-in templates (e.g. runner.yaml) — not auto-rendered
│   └── *.yaml               # Generated manifests — run `make generate-k8s` to refresh
├── docker/runner/           # Self-hosted GitHub Actions runner Dockerfile
├── .github/workflows/       # CI workflow (ci.yml.disabled — rename to enable)
├── .githooks/               # Pre-commit hook (`make hooks-install` to enable)
├── scripts/                 # Cluster setup + admin token mint
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
| Tunnel | Cloudflare cloudflared |
| CI (optional) | GitHub Actions on a self-hosted DinD runner |

## Using This as a Template

All project-specific values (names, namespace, IPs, ports, domain, OAuth client ID, coverage floors) live in `project.yaml`. To reuse this project for a new service:

### 1. Update `project.yaml`

Edit every value:

```yaml
project_name: myservice            # used for k8s resource names, DB name, proto configmap
namespace: my-namespace            # k8s namespace
image_name: my-service             # backend container image name
web_image_name: my-service-web     # web container image name
public_domain: myservice.example.com
tunnel_secret_name: my-tunnel-creds
github_repo: https://github.com/you/your-repo
google_client_id: <id>.apps.googleusercontent.com   # leave "" to ship without sign-in
node_ip_lan: 192.168.x.x
node_ip_tailscale: 100.x.x.x
registry_port: 32000
api_prefix: /myservice/api         # must match proto HTTP annotations
grpc_nodeport: 30051
kong_nodeport: 30080
web_nodeport: 30090
coverage_global_min: 0.0           # raise as the test suite grows
coverage_package_min: 0.0
coverage_exempt_patterns:
```

### 2. Regenerate k8s manifests and web config

```bash
make generate-k8s
```

This renders all `k8s/templates/*.yaml` → `k8s/*.yaml` and writes `web/.env` with `VITE_GITHUB_REPO` and `VITE_GOOGLE_CLIENT_ID`.

### 3. Rename and update the protos

```bash
mv proto/greeter.proto proto/<project_name>.proto
# Edit:
#   - package name
#   - service name
#   - every HTTP annotation to start with your new api_prefix
#   - `import public "auth.proto";` at the top (umbrella for Kong)
make check-api-paths   # catch any annotations missing the prefix
make proto             # Go stubs
make web-proto         # TypeScript stubs
```

### 4. Update app code

- `web/src/App.tsx` — update endpoint paths and UI copy
- `web/src/api/auth.ts` — update the hard-coded `/greeter/api` prefix to match
- `web/vite.config.ts` + `web/nginx.conf` — update the `/greeter/` proxy path to match
- `main.go` — update service logic, DB table names

### 5. First-time cluster setup

Follow the steps in [`k8s/README.md`](k8s/README.md) to set up the registry, CNPG, Kong, the auth secret, and the Cloudflare tunnel.

### 6. Build and deploy

```bash
make docker-build && make deploy
make web-docker-build && make web-deploy
make kong-deploy   # only when proto annotations or Kong config changes
```

## Make Targets

| Target | Purpose |
|---|---|
| `make` / `make all` | Regenerate proto + build Go binary |
| `make build` | Compile `bin/server` |
| `make proto` | Regenerate Go gRPC stubs |
| `make web-proto` | Regenerate TypeScript gRPC stubs |
| `make check-api-paths` | Verify proto annotations include `api_prefix` |
| `make test` | Fast Go tests (sqlmock + interceptor matrix, no Docker) |
| `make test-integration` | Full suite incl. testcontainers (`-tags=integration`) |
| `make lint` | Full lint sweep |
| `make lint-new` | Lint only newly changed lines (used by pre-commit hook) |
| `make lint-fix` | Auto-fix formatting and simple issues |
| `make coverage-go` | Generate `coverage/go-coverage.{out,html,txt}` |
| `make coverage-check` | Enforce floors from project.yaml |
| `make docker-build` / `make web-docker-build` | Buildx multi-platform build + push |
| `make deploy` / `make web-deploy` | `kubectl apply` |
| `make deploy-all` | Apply every manifest in dependency order |
| `make kong-deploy` | Refresh proto configmaps + helm upgrade + Kong rollout |
| `make generate-k8s` | Render `k8s/templates/*.yaml` → `k8s/*.yaml` |
| `make generate-runner` | Render the opt-in self-hosted runner manifest |
| `make runner-build` / `make runner-deploy` | Build + deploy the runner image |
| `make registry-show` | List repos/tags in the cluster registry; flag live ones |
| `make registry-prune` | Delete stale tags + run GC inside the registry pod |
| `make hooks-install` | Point git at `.githooks/` for the pre-commit hook |
| `make loadtest` | 20 concurrent gRPC connections for 30s |
| `make db-cleanup` | `TRUNCATE echo_requests` |
| `make clean` | Remove `bin/` and the legacy `loadtest` binary |

Never call `go`, `protoc`, `golangci-lint`, or `kubectl` directly — use the targets. See `CLAUDE.md` for the rationale.

## Protobuf Workflow

The proto file is the **source of truth** for all service contracts. After any change:

```bash
make proto              # rebuilds pb/ (Go)
make web-proto          # rebuilds web/src/generated/ (TypeScript)
make check-api-paths    # enforce api_prefix on every annotation
cd web && npx tsc --noEmit   # verify TypeScript compiles
make test
make kong-deploy        # only when HTTP routes / new services change
make docker-build && make deploy
make web-docker-build && make web-deploy
```

> Generated stubs in `pb/` and `web/src/generated/` are committed. A failing `tsc --noEmit` after `make web-proto` means a breaking proto change that requires updates to the web app before it can be deployed.

## Development

```bash
make hooks-install      # one-time per clone — gates commits on lint + compile
make                    # regen proto + build server
make test               # fast tests
make lint               # full lint
make run                # run gRPC server locally (requires DATABASE_URL)
cd web && npm run dev   # web app dev server (proxies /greeter/* to Kong)
```

## CI (optional)

A GitHub Actions workflow is shipped as `.github/workflows/ci.yml.disabled` — GitHub ignores files that don't end in `.yml`/`.yaml`, so it's dormant by default. To enable:

1. Stand up the self-hosted runner: `make generate-runner && make runner-build`, create the `github-runner-secret`, then `make runner-deploy`. See the header of `k8s/templates/optional/runner.yaml`.
2. Rename: `mv .github/workflows/ci.yml.disabled .github/workflows/ci.yml`
3. Commit and push.

The workflow targets a runner labeled `[self-hosted, k8s, greeter]`. Update the label list if you rename `project_name`.

## One-Time Cluster Setup

See [`k8s/README.md`](k8s/README.md) for full infrastructure setup — registry, CNPG, Kong, the `greeter-auth` secret (step 6), and the Cloudflare tunnel.
