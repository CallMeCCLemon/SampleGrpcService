BINARY  := server

# ── Config ────────────────────────────────────────────────────────────────────
# All project-specific values are read from project.yaml.
# Edit project.yaml, then run `make generate-k8s` to refresh the k8s manifests.

ifeq ($(wildcard project.yaml),)
$(error project.yaml not found - this file is required. It ships with the repo.)
endif

# Read a scalar value from project.yaml. Usage: $(call cfg,key)
cfg = $(shell grep "^$(1):" project.yaml | head -1 | awk '{print $$2}')

PROJECT_NAME   := $(call cfg,project_name)
NAMESPACE      := $(call cfg,namespace)
IMAGE_NAME     := $(call cfg,image_name)
WEB_IMAGE_NAME := $(call cfg,web_image_name)
GITHUB_REPO    := $(call cfg,github_repo)
PUBLIC_DOMAIN  := $(call cfg,public_domain)
TUNNEL_SECRET  := $(call cfg,tunnel_secret_name)
NODE_IP_LAN    := $(call cfg,node_ip_lan)
NODE_IP_TS     := $(call cfg,node_ip_tailscale)
REGISTRY_PORT  := $(call cfg,registry_port)
GRPC_NODEPORT  := $(call cfg,grpc_nodeport)
KONG_NODEPORT  := $(call cfg,kong_nodeport)
WEB_NODEPORT   := $(call cfg,web_nodeport)
API_PREFIX     := $(call cfg,api_prefix)

# LAN registry — used in k8s manifests (pulled by cluster nodes over LAN)
REGISTRY_LAN   := $(NODE_IP_LAN):$(REGISTRY_PORT)
# Tailscale registry — used for pushing from the dev machine
REGISTRY_TS    := $(NODE_IP_TS):$(REGISTRY_PORT)

IMAGE          := $(REGISTRY_LAN)/$(IMAGE_NAME)
PUSH_IMAGE     := $(REGISTRY_TS)/$(IMAGE_NAME)
WEB_IMAGE      := $(REGISTRY_LAN)/$(WEB_IMAGE_NAME)
WEB_PUSH_IMAGE := $(REGISTRY_TS)/$(WEB_IMAGE_NAME)

# gRPC address for external tooling (grpcurl, loadtest).
# Override at the command line: make loadtest GRPC_ADDR=<host>:<port>
GRPC_ADDR      := $(NODE_IP_LAN):$(GRPC_NODEPORT)

PORT           := 50051
PROTO_DIR      := proto
PB_DIR         := pb
VERSION        := $(shell cat VERSION)
GIT_SHA        := $(shell git rev-parse --short HEAD)

# ── Targets ───────────────────────────────────────────────────────────────────
.PHONY: all build test test-all proto web-proto \
        docker-build docker-run deploy deploy-all \
        web-docker-build web-deploy \
        kong-deploy generate-k8s \
        loadtest db-cleanup \
        run clean

all: proto build

proto:
	protoc --go_out=$(PB_DIR) --go_opt=paths=source_relative \
	       --go-grpc_out=$(PB_DIR) --go-grpc_opt=paths=source_relative \
	       -I $(PROTO_DIR) -I third_party \
	       $(PROTO_DIR)/*.proto

web-proto:
	mkdir -p web/src/generated
	protoc \
	    --plugin=protoc-gen-ts_proto=web/node_modules/.bin/protoc-gen-ts_proto \
	    --ts_proto_out=web/src/generated \
	    --ts_proto_opt=esModuleInterop=true,outputServices=fetch-client,fetchType=native,constEnums=false \
	    -I $(PROTO_DIR) -I third_party \
	    $(PROTO_DIR)/*.proto

build:
	go build -o $(BINARY) .

test:
	go test -v ./...

test-all:
	DOCKER_HOST=$$(docker context inspect --format '{{.Endpoints.docker.Host}}') \
	    TESTCONTAINERS_RYUK_DISABLED=true \
	    go test -v -tags=integration ./...

docker-build:
	docker buildx build --platform linux/amd64,linux/arm64 \
	    -t $(PUSH_IMAGE):$(VERSION)-$(GIT_SHA) \
	    -t $(PUSH_IMAGE):latest \
	    --build-arg VERSION=$(VERSION)-$(GIT_SHA) \
	    --push .
	sed -i '' "s|$(IMAGE):.*|$(IMAGE):$(VERSION)-$(GIT_SHA)|" k8s/deployment.yaml

docker-run:
	docker run --rm -p $(PORT):$(PORT) $(IMAGE)

run:
	go run .

deploy:
	kubectl apply -f k8s/deployment.yaml

# Applies all manifests in dependency order: deployment.yaml first (creates the
# namespace), then everything else together. Excludes secrets.example.yaml and
# kong-values.yaml (Helm values, not a kubectl manifest).
deploy-all:
	kubectl apply -f k8s/deployment.yaml
	kubectl apply \
	    -f k8s/postgres.yaml \
	    -f k8s/registry.yaml \
	    -f k8s/cloudflared.yaml \
	    -f k8s/kong.yaml \
	    -f k8s/web-deployment.yaml

web-docker-build:
	docker buildx build --platform linux/amd64,linux/arm64 \
	    -t $(WEB_PUSH_IMAGE):$(VERSION)-$(GIT_SHA) \
	    -t $(WEB_PUSH_IMAGE):latest \
	    --build-arg VITE_GITHUB_REPO=$(GITHUB_REPO) \
	    --push \
	    web/
	sed -i '' "s|$(WEB_IMAGE):.*|$(WEB_IMAGE):$(VERSION)-$(GIT_SHA)|" k8s/web-deployment.yaml

web-deploy:
	kubectl apply -f k8s/web-deployment.yaml

kong-deploy:
	kubectl create configmap $(PROJECT_NAME)-proto \
	    --from-file=$(PROJECT_NAME).proto=$(PROTO_DIR)/$(PROJECT_NAME).proto \
	    --namespace kong \
	    --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap googleapis-protos \
	    --from-file=annotations.proto=third_party/google/api/annotations.proto \
	    --from-file=http.proto=third_party/google/api/http.proto \
	    --namespace kong \
	    --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/kong.yaml
	kubectl apply -f k8s/deployment.yaml

# Render k8s/templates/*.yaml → k8s/*.yaml using the values in project.yaml.
# Requires envsubst (macOS: brew install gettext).
# Run this after editing project.yaml, then review `git diff k8s/` and commit.
generate-k8s:
	@command -v envsubst >/dev/null 2>&1 || \
	    { echo "envsubst not found. Install with: brew install gettext"; exit 1; }
	@echo "Generating k8s manifests from k8s/templates/ using project.yaml..."
	@export \
	    PROJECT_NAME="$(PROJECT_NAME)" \
	    NAMESPACE="$(NAMESPACE)" \
	    IMAGE_NAME="$(IMAGE_NAME)" \
	    WEB_IMAGE_NAME="$(WEB_IMAGE_NAME)" \
	    REGISTRY_LAN="$(REGISTRY_LAN)" \
	    REGISTRY_TS="$(REGISTRY_TS)" \
	    IMAGE="$(IMAGE)" \
	    WEB_IMAGE="$(WEB_IMAGE)" \
	    GRPC_NODEPORT="$(GRPC_NODEPORT)" \
	    KONG_NODEPORT="$(KONG_NODEPORT)" \
	    WEB_NODEPORT="$(WEB_NODEPORT)" \
	    PUBLIC_DOMAIN="$(PUBLIC_DOMAIN)" \
	    TUNNEL_SECRET="$(TUNNEL_SECRET)" \
	    GITHUB_REPO="$(GITHUB_REPO)" \
	    REGISTRY_PORT="$(REGISTRY_PORT)" \
	    API_PREFIX="$(API_PREFIX)"; \
	for tmpl in k8s/templates/*.yaml; do \
	    out="k8s/$$(basename $$tmpl)"; \
	    envsubst < "$$tmpl" > "$$out"; \
	    echo "  $$tmpl -> $$out"; \
	done
	@printf '# Base environment — loaded in all Vite modes (dev and production build).\n# Values here are baked into the JS bundle at build time.\n#\n# This file is auto-updated by `make generate-k8s` from project.yaml.\n# Do not edit by hand; change github_repo in project.yaml instead.\nVITE_GITHUB_REPO=$(GITHUB_REPO)\n' > web/.env
	@echo "  project.yaml -> web/.env"
	@echo "Done. Review changes with 'git diff' and commit if correct."
	@echo "Note: docker-build will re-pin the image tags in deployment.yaml and web-deployment.yaml."

loadtest:
	go run ./cmd/loadtest -addr $(GRPC_ADDR) -concurrency 20 -duration 30s

db-cleanup:
	kubectl exec -n $(NAMESPACE) \
	    $$(kubectl get pod -n $(NAMESPACE) -l cnpg.io/cluster=$(PROJECT_NAME)-db \
	       -o jsonpath='{.items[0].metadata.name}') \
	    -- psql -U $(PROJECT_NAME) -c "TRUNCATE TABLE echo_requests;"

clean:
	rm -f $(BINARY)
	rm -f loadtest
