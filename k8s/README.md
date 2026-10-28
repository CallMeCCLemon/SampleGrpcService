# Kubernetes Infrastructure

All manifests for the `grpc-demo` namespace on the self-hosted Kubernetes cluster.

## Project Configuration

Before applying any manifests, all project-specific values (namespace, image names, IPs, ports, domain) are controlled by `project.yaml` in the repo root. The `k8s/*.yaml` files are **generated** from `k8s/templates/` — never edit them directly.

```bash
# After changing project.yaml:
make generate-k8s   # renders k8s/templates/*.yaml -> k8s/*.yaml
```

Requires `envsubst`: `brew install gettext` on macOS.

## Cluster Overview

```
Kubernetes Cluster
├── grpc-demo (namespace)                                   ← owned by this repo
│   ├── greeter              Deployment + NodePort :30051  Go gRPC server
│   ├── greeter-web          Deployment + NodePort :30090  React/Nginx web app
│   ├── greeter-service      ClusterIP :80                 Cloudflare tunnel target
│   ├── greeter-db           CNPG Cluster                  PostgreSQL (1 instance)
│   ├── greeter              TunnelRoute                   public hostname on the shared tunnel
│   └── greeter-http         Ingress (host-scoped)         Kong route + grpc-gateway plugin
│
├── cloudflare-tunnels (namespace)                          ← shared platform
│   └── cloudflared-home     Deployment (2 replicas)       shared tunnel connectors (ClusterTunnel "home")
│
├── kong (namespace)                                        ← shared platform
│   ├── greeter-proto        ConfigMap                     this repo's protos (make kong-deploy)
│   ├── kong-gateway-proxy   NodePort :30080               HTTP/JSON → gRPC gateway
│   └── kong-gateway-manager NodePort :31918               Kong admin UI
│
├── registry-system (namespace)                             ← shared platform
│   └── registry             NodePort :32000               Local container registry
│
└── cnpg-system (namespace)                                 ← shared platform
    └── cnpg-controller      Deployment                    CloudNativePG operator
```

The shared platform (Kong Helm release, registry, CNPG operator, org CI runner, MinIO) is installed and upgraded from the platform repo, currently [RiftboundEngine](https://github.com/latentlab-cc/Riftbound-Engine). Nothing here installs or upgrades it.

## Manifest Reference

| File | Description |
|------|-------------|
| `templates/*.yaml` | Parameterized source templates — edit these (or project.yaml), not the generated files |
| `deployment.yaml` | `greeter` gRPC service (Namespace + Deployment + NodePort). Pinned to `:latest` for bootstrap; CI moves the live tag with `make k8s-rollout` |
| `web-deployment.yaml` | `greeter-web` React app (Deployment + NodePort + ClusterIP for tunnel) |
| `tunnelroute.yaml` | `TunnelRoute`: publishes `public_domain` through the shared tunnel to `greeter-service:80` |
| `kong.yaml` | `KongPlugin` (grpc-gateway, proto at `/etc/kong/protos/<project>/<project>.proto`) + host-scoped `Ingress` |
| `postgres.yaml` | CNPG `Cluster` resource (1 instance, 5Gi) |
| `secrets.yaml` | **Gitignored**, for any project secrets you keep in a file; never commit |

## First-Time Setup

Assumes the shared platform is already running on the cluster.

### 1. Register this project's protos with Kong

```bash
make kong-register
```

Paste the printed block into the platform repo's `k8s/templates/kong-values.yaml`, then from the platform repo run `make generate-k8s && make kong-deploy`.

### 2. Namespace, database, and app manifests

```bash
make deploy-all
```

The CNPG operator creates a secret named `<project_name>-db-app` once the database is ready; the backend's `DATABASE_URL` reads from it.

### 3. Public hostname

Nothing to do by hand: `make deploy-all` applied `tunnelroute.yaml`, and
Cloudflare-Tunnel-Operator adds `public_domain` to the shared tunnel and creates
its proxied DNS record. Check it:

```bash
kubectl -n <namespace> get tunnelroute
# NAME      HOSTNAME                 TUNNEL   SERVICE                                              READY
# greeter   grpc-demo.latentlab.cc   home     http://greeter-service.grpc-demo.svc.cluster.local:80   True
```

If it isn't Ready, `kubectl -n <namespace> describe tunnelroute <project_name>` says
why. `DNSRecordConflict` means the hostname already has a DNS record from an older
setup: set `tunnel_adopt_dns: true` in `project.yaml`, run `make generate-k8s`, and
apply `k8s/tunnelroute.yaml` again.

### 4. Auth secret (Google sign-in)

The backend reads `GOOGLE_CLIENT_ID` and `JWT_SECRET` from a Kubernetes secret named `<project_name>-auth`. The pod stays in `CreateContainerConfigError` until it exists.

```bash
# Create your OAuth client ID at:
#   https://console.cloud.google.com/apis/credentials
# (Application type: Web application. Add https://<public_domain> and
# http://localhost:5173 to "Authorized JavaScript origins".)

CLIENT_ID="<your-id>.apps.googleusercontent.com"

kubectl create secret generic greeter-auth \
  --namespace grpc-demo \
  --from-literal=google-client-id="$CLIENT_ID" \
  --from-literal=jwt-secret="$(openssl rand -base64 48)"
```

Also set `google_client_id` in `project.yaml` and run `make generate-k8s` so the web bundle gets it.

`jwt-secret` is the HMAC-SHA256 key used to sign session JWTs. Generate it once and persist; rotating it invalidates every active session.

To make a user an admin (e.g. so they can call `ListUsers`):

```bash
kubectl exec -n grpc-demo \
  $(kubectl get pod -n grpc-demo -l cnpg.io/cluster=greeter-db -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U greeter -c "UPDATE users SET is_admin = true WHERE email = '<their-email>';"
```

### 5. Kong routes and first rollout

```bash
make kong-deploy   # proto configmap + Ingress, restarts Kong because the configmap is new
make release       # build + push both images, then k8s-rollout
```

After this, pushes to `main` deploy through CI.

## Kong gateway constraints

Kong's `grpc-gateway` plugin is a Lua reimplementation, not the Go `grpc-ecosystem/grpc-gateway`, and behaves differently:

- **Paths include the full prefix.** The plugin matches the original request path, before any strip-path rewrite, so every `google.api.http` annotation must start with `api_prefix`. `make check-api-paths` enforces this.
- **Every HTTP route must be reachable from `<project>.proto`.** The plugin loads only that file and its import graph. A service in another file needs `import public "<file>.proto";` in the umbrella proto, or its routes return `400 ... Unknown path`. RPCs with no HTTP annotation (internal admin tools over gRPC) need no import.
- **New routes need a Kong restart.** The plugin reads the proto into memory at startup and ignores configmap updates. `make kong-deploy` restarts the gateway when the configmap changed and skips the restart otherwise.
- **No `repeated` fields as GET query params.** A single value (`?colors=RED`) fails with `400 failed to encode payload`; only two or more values work ([Kong#14907](https://github.com/Kong/kong/issues/14907)). Use a comma-separated string field instead, or a POST body.
- **Well-known types** (`google/protobuf/wrappers.proto` etc.) resolve from the platform's `protobuf-wkt-protos` configmap, mounted under each project's directory. Copy any new one you import into `third_party/google/protobuf/` for local codegen and make sure the platform configmap includes it.

## Ongoing Operations

### Protobuf changes

```bash
make proto && make web-proto && make check-api-paths && make test
```

Push to `main`; CI runs `make kong-deploy`, which restarts Kong only if the protos changed.

### Registry

```bash
make registry-show    # every repo/tag, live tags marked
make registry-prune   # delete this project's stale tags (CI runs this after each rollout)
```

Tag deletes do not free disk; the registry-wide garbage-collect runs from the platform repo.

### Database cleanup

```bash
make db-cleanup   # TRUNCATEs echo_requests
```

### Load testing

```bash
make loadtest   # 20 concurrent gRPC connections for 30s against GRPC_ADDR
# Override target: make loadtest GRPC_ADDR=<host>:<port>
```

## Networking

All addresses below reflect the defaults in `project.yaml`. Update that file to change them.

```
External / Tailscale (node_ip_tailscale)
  <tailscale-ip>:30080  →  Kong proxy      (HTTP/JSON API, shared; requires Host: <public_domain>)
  <tailscale-ip>:30051  →  greeter gRPC    (direct gRPC)
  <tailscale-ip>:30090  →  greeter-web     (React UI)
  <tailscale-ip>:32000  →  registry        (image push from dev machine)

LAN (node_ip_lan)
  Same NodePorts above; k8s nodes and CI runners push/pull images on :32000 over LAN

Public
  https://<public_domain>  →  shared Cloudflare tunnel → <project_name>-service.<namespace>:80
```

Inside the cluster, services communicate using k8s DNS (no IPs):

| From | To | Address |
|------|----|---------|
| `greeter-web` Nginx | Kong | `kong-gateway-proxy.kong:80` (forwards the original Host) |
| `cloudflared-home` (shared tunnel) | Web app | `greeter-service.grpc-demo.svc.cluster.local:80` |
| `greeter` | PostgreSQL | `greeter-db-rw.grpc-demo:5432` (from CNPG secret) |
