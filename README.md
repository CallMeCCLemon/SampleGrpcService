# SampleGrpcProject

A testbed for exploring how to wire together a Go-based gRPC service, a PostgreSQL database, an HTTP-to-gRPC gateway using Kong, and a React web front-end — all running on a self-hosted k3s cluster exposed via a Cloudflare tunnel.

## Architecture

```
                        ┌─────────────────────────────────────────┐
                        │           k3s Cluster (grpc-demo ns)    │
                        │                                          │
Browser / curl          │  ┌──────────────┐    ┌───────────────┐  │
    │                   │  │  greeter-web  │    │    greeter    │  │
    │  HTTPS             │  │  (Nginx)      │    │  (Go gRPC)   │  │
    ▼                   │  │              │    │               │  │
┌──────────────┐        │  │  Serves SPA  │    │  SayHello     │  │
│  Cloudflare  │        │  │  Proxies API │───▶│  SayGoodbye   │  │
│  Tunnel      │───────▶│  └──────┬───────┘    └──────┬────────┘  │
└──────────────┘        │         │                    │           │
    │                   │  ┌──────▼───────┐    ┌──────▼────────┐  │
    │  HTTP (NodePort)  │  │     Kong     │    │  PostgreSQL   │  │
    ▼                   │  │  API Gateway │    │  (CNPG)       │  │
┌──────────────┐        │  │  HTTP/JSON   │    │               │  │
│  LAN clients │───────▶│  │  ↔ gRPC     │    │  hello_reqs   │  │
└──────────────┘        │  └──────────────┘    │  goodbye_reqs │  │
                        │                      └───────────────┘  │
                        └─────────────────────────────────────────┘
```

**Public URL:** `https://grpc-demo.latentlab.cc` (via Cloudflare tunnel → `grpc-demo-service` ClusterIP)

**LAN access:**

| Service       | Address                       |
|---------------|-------------------------------|
| Web UI        | `http://<node-ip>:30090`      |
| Kong proxy    | `http://<node-ip>:30080`      |
| gRPC direct   | `<node-ip>:30051`             |

## Repository Layout

```
SampleGrpcProject/
├── proto/               # Protobuf definitions (source of truth)
├── pb/                  # Generated Go gRPC stubs (committed)
├── internal/
│   ├── logger/          # slog-based JSON logger
│   └── db/              # GORM DB layer + tests
├── cmd/loadtest/        # gRPC load test tool
├── web/                 # React + TypeScript front-end (see web/README.md)
├── k8s/                 # Kubernetes manifests (see k8s/README.md)
├── scripts/             # One-time cluster setup scripts
├── main.go              # gRPC server entry point
├── Makefile
└── VERSION              # Semver source of truth
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/hello` | Greet by name, persists request to DB |
| `POST` | `/goodbye` | Farewell by name, persists request to DB |

```bash
# Via Kong NodePort
curl -X POST http://<node-ip>:30080/hello \
  -H 'Content-Type: application/json' \
  -d '{"name": "World"}'

# Via gRPC directly
grpcurl -plaintext -d '{"name": "World"}' <node-ip>:30051 greeter.Greeter/SayHello
```

## Stack

| Layer | Technology |
|-------|-----------|
| Front-end | React 18 + TypeScript, Vite, Nginx |
| API Gateway | Kong (grpc-gateway plugin, HTTP/JSON ↔ gRPC) |
| gRPC Service | Go 1.25, GORM, CloudNativePG |
| Database | PostgreSQL via CNPG operator on k3s |
| Cluster | k3s (multi-node, self-hosted) |
| Tunnel | Cloudflare cloudflared |

## Protobuf Workflow

The proto file (`proto/greeter.proto`) is the **source of truth** for all service contracts. After any change, regenerate both the Go stubs and the TypeScript client:

```bash
# 1. Edit proto/greeter.proto

# 2. Regenerate Go stubs and TypeScript client
make proto        # rebuilds pb/ (Go)
make web-proto    # rebuilds web/src/generated/ (TypeScript)

# 3. Verify TypeScript still compiles cleanly
cd web && npx tsc --noEmit

# 4. Run tests to catch any Go-side breakage
make test

# 5. Rebuild and redeploy both services
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
cd web && npm run dev   # Run web app locally (proxies /hello, /goodbye to Kong)
```

## Build & Deploy

```bash
# Bump VERSION file, then:
make docker-build       # Multi-platform Go server build + push via Tailscale
make deploy             # kubectl apply + rolling image update

make web-docker-build   # Multi-platform web app build + push via Tailscale
make web-deploy         # kubectl apply
```

Images are pushed to the local registry via Tailscale (`100.69.236.43:32000`) and pulled by k8s nodes over LAN (`192.168.1.110:32000`). Both addresses point to the same registry pod.

## One-Time Cluster Setup

See [`k8s/README.md`](k8s/README.md) for full infrastructure setup instructions.
