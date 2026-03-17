# SampleGrpcProject

A testbed — and reusable template — for wiring together a Go-based gRPC service, a PostgreSQL database, an HTTP-to-gRPC gateway using Kong, and a React web front-end, all running on a self-hosted Kubernetes cluster exposed via a Cloudflare tunnel.

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
  │  │  · proxies /api/* to Kong      │  │
  │  └───────────────┬────────────────┘  │
  │                  │ HTTP/JSON         │
  │                  ▼                   │
  │  ┌────────────────────────────────┐  │
  │  │  Kong API Gateway              │  │◀── :30080
  │  │  · grpc-gateway plugin         │  │
  │  │  · HTTP/JSON ↔ gRPC            │  │
  │  └───────────────┬────────────────┘  │
  │                  │ gRPC              │
  │                  ▼                   │
  │  ┌────────────────────────────────┐  │
  │  │  greeter (Go gRPC)             │  │◀── :30051
  │  │  · SayHello                    │  │
  │  │  · SayGoodbye                  │  │
  │  └───────────────┬────────────────┘  │
  │                  │                   │
  │                  ▼                   │
  │  ┌────────────────────────────────┐  │
  │  │  PostgreSQL (CNPG)             │  │
  │  │  · hello_requests              │  │
  │  │  · goodbye_requests            │  │
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
├── project.yaml         # Single source of truth for all project-specific config
├── proto/               # Protobuf definitions (source of truth for service contracts)
├── pb/                  # Generated Go gRPC stubs (committed)
├── internal/
│   ├── logger/          # slog-based JSON logger
│   └── db/              # GORM DB layer + tests
├── cmd/loadtest/        # gRPC load test tool
├── web/                 # React + TypeScript front-end (see web/README.md)
├── k8s/
│   ├── templates/       # Parameterized manifest templates (envsubst variables)
│   └── *.yaml           # Generated manifests — run `make generate-k8s` to refresh
├── scripts/             # One-time cluster setup scripts
├── main.go              # gRPC server entry point
├── Makefile
└── VERSION              # Semver source of truth
```

## Endpoints

Kong exposes these endpoints directly (HTTP/JSON → gRPC transcoding):

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/hello` | Greet by name, persists request to DB |
| `POST` | `/goodbye` | Farewell by name, persists request to DB |

The web app calls these via an `/api/` prefix that Nginx and the Vite dev proxy both strip before forwarding to Kong (e.g. `POST /api/hello` → Kong receives `POST /hello`).

```bash
# Via Kong NodePort (direct — no /api prefix needed)
curl -X POST http://<node-ip>:30080/hello \
  -H 'Content-Type: application/json' \
  -d '{"name": "World"}'

# Via gRPC directly
grpcurl -plaintext -d '{"name": "World"}' <node-ip>:30051 greeter.Greeter/SayHello
```

## Stack

| Layer | Technology |
|-------|------------|
| Front-end | React 18 + TypeScript, Vite, Nginx |
| API Gateway | Kong (grpc-gateway plugin, HTTP/JSON ↔ gRPC) |
| gRPC Service | Go 1.25, GORM, CloudNativePG |
| Database | PostgreSQL via CNPG operator on k8s |
| Cluster | k8s (multi-node, self-hosted) |
| Tunnel | Cloudflare cloudflared |

## Using This as a Template

All project-specific values (names, namespace, IPs, ports, domain) live in `project.yaml`. To reuse this project for a new service:

### 1. Update project.yaml

Edit every value in `project.yaml` to match your new project:

```yaml
project_name: myservice        # used for k8s resource names, DB name, proto configmap
namespace: my-namespace        # k8s namespace
image_name: my-service         # container image name for the gRPC backend
web_image_name: my-service-web # container image name for the web front-end
github_repo: https://github.com/you/your-repo
public_domain: myservice.example.com
tunnel_secret_name: my-tunnel-creds
node_ip_lan: 192.168.x.x
node_ip_tailscale: 100.x.x.x
registry_port: 32000
grpc_nodeport: 30051
kong_nodeport: 30080
web_nodeport: 30090
```

### 2. Regenerate k8s manifests and web config

```bash
# Requires envsubst: brew install gettext
make generate-k8s
```

This renders all `k8s/templates/*.yaml` → `k8s/*.yaml` and writes `web/.env` with your GitHub repo URL.

### 3. Rename and update the proto

```bash
mv proto/greeter.proto proto/<project_name>.proto
# Edit the proto: update the package name, service name, and HTTP route paths
```

Then regenerate stubs:

```bash
make proto        # Go stubs (pb/)
make web-proto    # TypeScript types (web/src/generated/)
cd web && npx tsc --noEmit   # verify TypeScript compiles
```

### 4. Update app code

- `web/src/App.tsx` — update endpoint paths and UI copy to match your new service
- `main.go` — update service logic, DB table names, etc.

### 5. First-time cluster setup

Follow the steps in [`k8s/README.md`](k8s/README.md) to set up the registry, CNPG, Kong, and Cloudflare tunnel on your cluster.

### 6. Build and deploy

```bash
make docker-build && make deploy
make web-docker-build && make web-deploy
```

## Protobuf Workflow

The proto file is the **source of truth** for all service contracts. After any change, regenerate both the Go stubs and the TypeScript client:

```bash
# 1. Edit proto/<project_name>.proto

# 2. Regenerate Go stubs and TypeScript client
make proto        # rebuilds pb/ (Go)
make web-proto    # rebuilds web/src/generated/ (TypeScript)

# 3. Verify TypeScript still compiles cleanly
cd web && npx tsc --noEmit

# 4. Run tests to catch any Go-side breakage
make test

# 5. Rebuild proto configmaps and redeploy
make kong-deploy
make docker-build && make deploy
make web-docker-build && make web-deploy
```

> The generated TypeScript types in `web/src/generated/` are committed to the repo.
> A failing `tsc --noEmit` after `make web-proto` means a breaking proto change
> that requires updates to the web app before it can be deployed.

## Development

```bash
make              # Regenerate proto + build Go binary
make test         # Fast tests (sqlmock + gRPC integration, no Docker)
make test-all     # All tests including testcontainers integration suite
make run          # Run gRPC server locally
cd web && npm run dev   # Run web app locally (proxies /api/* to Kong)
```

## Build & Deploy

All registry addresses and image names are read from `project.yaml`. No hardcoded IPs in the Makefile.

```bash
# Bump VERSION file, then:
make docker-build       # Multi-platform Go server build + push
make deploy             # kubectl apply

make web-docker-build   # Multi-platform web app build + push
make web-deploy         # kubectl apply
```

Images are pushed via Tailscale (`node_ip_tailscale` in project.yaml) and pulled by k8s nodes over LAN (`node_ip_lan`). Both point to the same registry pod.

## One-Time Cluster Setup

See [`k8s/README.md`](k8s/README.md) for full infrastructure setup instructions.
