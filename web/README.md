# Web Front-End

React + TypeScript single-page application that demonstrates calling the Greeter gRPC service via Kong's HTTP/JSON transcoding.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Dev (local machine)                                        │
│                                                             │
│  Browser → localhost:5173                                   │
│               │                                             │
│               ▼                                             │
│          Vite dev server                                    │
│          (HMR enabled)                                      │
│               │  POST /api/hello, /api/goodbye              │
│               │  (strips /api prefix before forwarding)     │
│               ▼                                             │
│          Kong NodePort  ←─ KONG_URL in .env.development     │
│          receives POST /hello, /goodbye                     │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Production (k3s cluster, grpc-demo namespace)              │
│                                                             │
│  Browser → grpc-demo.latentlab.cc                           │
│               │ HTTPS                                       │
│               ▼                                             │
│          Cloudflare Tunnel                                  │
│               │                                             │
│               ▼                                             │
│          greeter-service (ClusterIP :80)                    │
│               │                                             │
│               ▼                                             │
│          greeter-web pod (Nginx)                            │
│          ├── GET /           →  React SPA (static files)    │
│          └── POST /api/*     →  strips /api prefix          │
│                                 proxy_pass                  │
│                                 ▼                           │
│                    kong-gateway-proxy.kong:80               │
│                    receives POST /hello, /goodbye           │
│                    (k8s internal DNS, no hard-coded IPs)    │
└─────────────────────────────────────────────────────────────┘
```

## API Prefix Convention

All API calls use an `/api/` prefix. Nginx and the Vite dev proxy both strip this prefix before forwarding to Kong, so Kong always receives the paths defined in the proto (`/hello`, `/goodbye`).

This keeps React Router client-side routes (`/about`, `/profile`, etc.) from conflicting with the Kong proxy — anything without the `/api/` prefix is served by Nginx as the SPA.

## Local Development

```bash
npm install
npm run dev
```

The Vite dev server proxies all `/api/*` requests to Kong, stripping the `/api` prefix. The target URL is read from `KONG_URL` in `.env.development`.

To override for your machine without changing committed files, create:

```bash
# web/.env.development.local  (gitignored by Vite)
KONG_URL=http://<your-node-ip>:30080
```

## Protobuf Workflow

TypeScript types are generated from `proto/greeter.proto` into `src/generated/` using [ts-proto](https://github.com/stephenh/ts-proto). The generated files are **committed** to the repo so that `tsc` acts as a breaking-change detector.

### After any proto change

Run all of the following from the **repository root**:

```bash
# Step 1 — regenerate Go stubs and TypeScript types
make proto        # rebuilds pb/  (Go)
make web-proto    # rebuilds web/src/generated/  (TypeScript)

# Step 2 — verify the TypeScript app still compiles
cd web && npx tsc --noEmit

# Step 3 — run Go tests to catch server-side breakage
make test

# Step 4 — rebuild and redeploy both services
make docker-build    && make deploy
make web-docker-build && make web-deploy
```

> If `tsc --noEmit` fails after `make web-proto`, it means a field or type used
> in the app no longer exists in the updated proto. Fix the app code first.

### Generated file reference

| File | Contents |
|------|----------|
| `src/generated/greeter.ts` | `HelloRequest`, `HelloReply`, `GoodbyeRequest`, `GoodbyeReply` interfaces + JSON helpers |
| `src/generated/google/` | Transitive google proto types — not used directly by the app, excluded from strict tsconfig |

## Building for Production

```bash
# From the repo root:
make web-docker-build   # builds multi-platform image, pushes, pins tag in k8s/web-deployment.yaml
make web-deploy         # kubectl apply -f k8s/web-deployment.yaml
```

The Docker build passes `VITE_GITHUB_REPO` as a build arg (sourced from `project.yaml` via the Makefile) and runs `tsc -b && vite build` — a type error from a proto mismatch will fail the build.

## Project Structure

```
web/
├── src/
│   ├── App.tsx               # Main UI: name input + SayHello / SayGoodbye buttons
│   ├── App.css               # Styles
│   ├── main.tsx              # React entry point
│   └── generated/            # Auto-generated from proto — DO NOT EDIT BY HAND
│       ├── greeter.ts        # Greeter service types
│       └── google/           # Transitive google proto types
├── nginx.conf                # Nginx: serves SPA + proxies /api/* to Kong (strips prefix)
├── Dockerfile                # Multi-stage: Node build → Nginx
├── .env                      # Base env: VITE_GITHUB_REPO (auto-updated by make generate-k8s)
├── .env.development          # Dev Kong proxy URL (override via .env.development.local)
├── vite.config.ts            # Vite: HMR + /api/* Kong dev proxy (strips /api prefix)
├── tsconfig.app.json         # TypeScript: strict mode, erasableSyntaxOnly
└── package.json
```
