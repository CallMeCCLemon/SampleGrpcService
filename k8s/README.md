# Kubernetes Infrastructure

All manifests for the `grpc-demo` namespace on the self-hosted k3s cluster.

## Cluster Overview

```
k3s Cluster
├── grpc-demo (namespace)
│   ├── greeter              Deployment + NodePort :30051  Go gRPC server
│   ├── greeter-web          Deployment + NodePort :30090  React/Nginx web app
│   ├── grpc-demo-service    ClusterIP :80                 Cloudflare tunnel target
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
| `deployment.yaml` | `greeter` gRPC service (Deployment + NodePort) |
| `web-deployment.yaml` | `greeter-web` React app (Deployment + NodePort + ClusterIP for tunnel) |
| `cloudflared.yaml` | Cloudflare tunnel agent (reads token from `sample-grpc-demo-tunnel-creds` secret) |
| `kong.yaml` | Kong `KongPlugin` (grpc-gateway) + `Ingress` routing `/hello` and `/goodbye` |
| `kong-values.yaml` | Helm values for Kong Ingress Controller (NodePort, proto volume mounts) |
| `postgres.yaml` | CNPG `Cluster` resource (`greeter-db`, 1 instance, 5Gi) |
| `registry.yaml` | Local `registry:2` pod + NodePort :32000 + PVC |
| `secrets.example.yaml` | Template for the Cloudflare tunnel secret — copy and fill in token |
| `secrets.yaml` | **Gitignored** — real secret, never commit |

## First-Time Setup

### 1. Namespace

```bash
kubectl apply -f k8s/deployment.yaml   # also creates the grpc-demo namespace
```

### 2. PostgreSQL (CNPG)

```bash
# Install the CNPG operator (one-time per cluster)
./scripts/install-cnpg.sh

# Deploy the database cluster
kubectl apply -f k8s/postgres.yaml
```

The operator creates the `greeter-db-app` secret automatically once the cluster is ready. The `DATABASE_URL` env var in the `greeter` deployment reads from this secret.

### 3. Local Container Registry

```bash
# Run on EVERY k3s node (server + agents):
sudo ./scripts/setup-registry.sh
# Configures both LAN (192.168.1.110:32000) and Tailscale (100.69.236.43:32000)
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
# Create the tunnel token secret (see secrets.example.yaml)
cp k8s/secrets.example.yaml k8s/secrets.yaml
# Edit k8s/secrets.yaml — replace <your-cloudflare-tunnel-token>
kubectl apply -f k8s/secrets.yaml

# Deploy the cloudflared agent
kubectl apply -f k8s/cloudflared.yaml
```

> Get your tunnel token from the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com) →
> Networks → Tunnels → your tunnel → Configure → Install connector.

### 6. Deploy the Applications

```bash
make docker-build && make deploy          # gRPC backend
make web-docker-build && make web-deploy  # React web app
```

## Ongoing Operations

### Protobuf changes

After editing `proto/greeter.proto`, regenerate all clients and redeploy:

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

# Rebuild and redeploy both services
make docker-build    && make deploy
make web-docker-build && make web-deploy
```

### Updating Kong after proto changes

Kong's `grpc-gateway` plugin reads the proto file from a ConfigMap mounted into the pod. `make kong-deploy` recreates those ConfigMaps and re-applies the ingress rules. After running it, restart the Kong pod to pick up the new mount:

```bash
kubectl rollout restart deployment -n kong
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

```
External / Tailscale
  100.69.236.43:30080  →  Kong proxy      (HTTP/JSON API)
  100.69.236.43:30051  →  greeter gRPC    (direct gRPC)
  100.69.236.43:30090  →  greeter-web     (React UI)
  100.69.236.43:32000  →  registry        (image push from dev machine)

LAN (192.168.1.110)
  Same NodePorts above, plus k8s node pulls images from :32000 over LAN

Public
  https://grpc-demo.latentlab.cc  →  Cloudflare tunnel → grpc-demo-service:80
```

Inside the cluster, services communicate using k8s DNS (no IPs):

| From | To | Address |
|------|----|---------|
| `greeter-web` Nginx | Kong | `kong-gateway-proxy.kong:80` |
| `cloudflared` | Web app | `grpc-demo-service.grpc-demo:80` |
| `greeter` | PostgreSQL | `greeter-db-rw.grpc-demo:5432` (from CNPG secret) |
