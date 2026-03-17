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
├── grpc-demo (namespace)
│   ├── greeter              Deployment + NodePort :30051  Go gRPC server
│   ├── greeter-web          Deployment + NodePort :30090  React/Nginx web app
│   ├── greeter-service      ClusterIP :80                 Cloudflare tunnel target
│   ├── greeter-db           CNPG Cluster                  PostgreSQL (1 instance)
│   └── cloudflared          Deployment (2 replicas)       Cloudflare tunnel agent
│
├── kong (namespace)
│   ├── kong-gateway-proxy   NodePort :30080               HTTP/JSON → gRPC gateway
│   └── kong-gateway-manager NodePort :31918               Kong admin UI
│
├── registry-system (namespace)
│   └── registry             NodePort :32000               Local container registry
│
└── cnpg-system (namespace)
    └── cnpg-controller      Deployment                    CloudNativePG operator
```

## Manifest Reference

| File | Description |
|------|-------------|
| `templates/*.yaml` | Parameterized source templates — edit these (or project.yaml), not the generated files |
| `deployment.yaml` | `greeter` gRPC service (Namespace + Deployment + NodePort) |
| `web-deployment.yaml` | `greeter-web` React app (Deployment + NodePort + ClusterIP for tunnel) |
| `cloudflared.yaml` | Cloudflare tunnel agent (reads token from secret named in project.yaml) |
| `kong.yaml` | Kong `KongPlugin` (grpc-gateway) + `Ingress` routing all traffic through Kong |
| `kong-values.yaml` | Helm values for Kong Ingress Controller (NodePort, proto volume mounts) |
| `postgres.yaml` | CNPG `Cluster` resource (1 instance, 5Gi) |
| `registry.yaml` | Local `registry:2` pod + NodePort + PVC |
| `secrets.example.yaml` | Template for the Cloudflare tunnel secret — copy and fill in token |
| `secrets.yaml` | **Gitignored** — real secret, never commit |

## First-Time Setup

### 0. Configure project.yaml

Before anything else, edit `project.yaml` in the repo root with your node IPs, desired namespace, image names, and NodePorts. Then generate the manifests:

```bash
make generate-k8s
```

### 1. Namespace

```bash
kubectl apply -f k8s/deployment.yaml   # also creates the namespace
```

### 2. PostgreSQL (CNPG)

```bash
# Install the CNPG operator (one-time per cluster)
./scripts/install-cnpg.sh

# Deploy the database cluster
kubectl apply -f k8s/postgres.yaml
```

The operator creates a secret named `<project_name>-db-app` automatically once the cluster is ready. The `DATABASE_URL` env var in the backend deployment reads from this secret.

### 3. Local Container Registry

```bash
# Run on EVERY node (server + agents).
# Defaults to the IPs set in project.yaml (node_ip_lan and node_ip_tailscale).
sudo ./scripts/setup-registry.sh

# Or pass IPs explicitly:
sudo ./scripts/setup-registry.sh 32000 192.168.x.x 100.x.x.x
```

### 4. Kong API Gateway

```bash
# Add the Kong Helm repo (one-time)
helm repo add kong https://charts.konghq.com && helm repo update

# Install the Kong Ingress Controller
helm upgrade --install kong kong/ingress \
  --namespace kong --create-namespace \
  --values k8s/kong-values.yaml

# Deploy proto configmaps + Kong ingress rules
make kong-deploy
```

### 5. Cloudflare Tunnel

```bash
# Create the tunnel token secret
cp k8s/secrets.example.yaml k8s/secrets.yaml
# Edit k8s/secrets.yaml — replace <your-cloudflare-tunnel-token>
kubectl apply -f k8s/secrets.yaml

# Deploy the cloudflared agent
kubectl apply -f k8s/cloudflared.yaml
```

In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com) → Networks → Tunnels → your tunnel → Public Hostname, set the target to:
```
http://<project_name>-service.<namespace>:80
```
(e.g. `http://greeter-service.grpc-demo:80`)

> Get your tunnel token from the dashboard → Networks → Tunnels → your tunnel → Configure → Install connector.

### 6. Deploy the Applications

```bash
make docker-build && make deploy          # gRPC backend
make web-docker-build && make web-deploy  # React web app
```

## Ongoing Operations

### Protobuf changes

After editing `proto/<project_name>.proto`, regenerate all clients and redeploy:

```bash
# Regenerate stubs
make proto          # Go (pb/)
make web-proto      # TypeScript (web/src/generated/)

# Verify TypeScript compiles
cd web && npx tsc --noEmit && cd ..

# Run tests
make test

# Rebuild proto configmaps so Kong picks up the new definitions
make kong-deploy

# Restart Kong to pick up the new proto ConfigMap mount
kubectl rollout restart deployment -n kong

# Rebuild and redeploy both services
make docker-build    && make deploy
make web-docker-build && make web-deploy
```

### Database cleanup

```bash
make db-cleanup   # TRUNCATEs hello_requests and goodbye_requests
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
  <tailscale-ip>:30080  →  Kong proxy      (HTTP/JSON API)
  <tailscale-ip>:30051  →  greeter gRPC    (direct gRPC)
  <tailscale-ip>:30090  →  greeter-web     (React UI)
  <tailscale-ip>:32000  →  registry        (image push from dev machine)

LAN (node_ip_lan)
  Same NodePorts above, plus k8s nodes pull images from :32000 over LAN

Public
  https://<public_domain>  →  Cloudflare tunnel → <project_name>-service.<namespace>:80
```

Inside the cluster, services communicate using k8s DNS (no IPs):

| From | To | Address |
|------|----|---------|
| `greeter-web` Nginx | Kong | `kong-gateway-proxy.kong:80` |
| `cloudflared` | Web app | `greeter-service.grpc-demo:80` |
| `greeter` | PostgreSQL | `greeter-db-rw.grpc-demo:5432` (from CNPG secret) |
