# SampleGrpcProject

A testbed for exploring how to wire together a Go-based gRPC service, a PostgreSQL database, and an HTTP-to-gRPC gateway using Kong.

## What It Does

The service exposes a `Greeter` gRPC API (`SayHello`, `SayGoodbye`) backed by a PostgreSQL database that records each request. HTTP clients invoke the service through a Kong API Gateway, which transcodes HTTP/JSON calls to gRPC using the `grpc-gateway` plugin — no gRPC client required.

```
HTTP Client
    │
    ▼
Kong API Gateway (HTTP/JSON → gRPC transcoding)
    │
    ▼
Go gRPC Service (greeter)
    │
    ▼
PostgreSQL (CNPG)
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/hello` | Greet by name, persists request to DB |
| `POST` | `/goodbye` | Farewell by name, persists request to DB |

Example:
```bash
curl -X POST http://<node-ip>:30080/hello \
  -H 'Content-Type: application/json' \
  -d '{"name": "World"}'
```

## Stack

- **Go 1.25** — gRPC server with unary logging interceptor and health check
- **PostgreSQL** — managed by the [CloudNativePG](https://cloudnative-pg.io/) operator (CNPG) on k3s
- **GORM** — ORM layer with `AutoMigrate` for schema management
- **Kong** — Kubernetes Ingress controller with `grpc-gateway` plugin for HTTP/JSON transcoding
- **k3s** — Lightweight Kubernetes cluster (multi-node, Dell amd64 worker)

## Development

```bash
make          # Regenerate proto + build binary
make test     # Fast tests (sqlmock + gRPC integration, no Docker needed)
make test-all # All tests including testcontainers integration suite
make run      # Run locally
```

## Build & Deploy

```bash
# Bump VERSION file, then:
make docker-build   # Multi-platform build (linux/amd64 + linux/arm64) + push
make deploy         # kubectl apply + rolling image update
```

See the `Makefile` for all available targets.
