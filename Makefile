BINARY  := bin/server

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
GO_COVERAGE_GLOBAL_MIN      := $(call cfg,coverage_global_min)
GO_COVERAGE_PACKAGE_MIN     := $(call cfg,coverage_package_min)
GO_COVERAGE_EXEMPT_PATTERNS := $(call cfg,coverage_exempt_patterns)
GOOGLE_CLIENT_ID            := $(call cfg,google_client_id)

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
# Prefer the CI-provided commit SHA when running under GitHub Actions; fall back
# to the local git checkout for dev builds. Shallow CI checkouts may not have
# git history, so reading $GITHUB_SHA directly is more reliable there.
GIT_SHA        := $(if $(GITHUB_SHA),$(shell echo "$(GITHUB_SHA)" | cut -c1-7),$(shell git rev-parse --short HEAD 2>/dev/null || echo dev))

# Cross-platform sed -i: macOS BSD sed requires an explicit empty suffix (''),
# GNU/Linux sed does not accept it as a separate argument.
ifeq ($(shell uname),Darwin)
  SED_INPLACE = sed -i ''
else
  SED_INPLACE = sed -i
endif

# ── Targets ───────────────────────────────────────────────────────────────────
.PHONY: all build test test-integration proto web-proto check-api-paths \
        lint lint-install lint-new lint-fix \
        coverage coverage-go coverage-check \
        docker-build docker-run deploy deploy-all \
        web-docker-build web-deploy \
        kong-deploy generate-k8s generate-runner \
        runner-build runner-deploy \
        registry-show registry-prune \
        hooks-install \
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

# Verify every HTTP annotation in the proto starts with api_prefix from
# project.yaml. Kong's grpc-gateway plugin matches the ORIGINAL request path,
# so under our strip-path: "false" routing the proto annotations must include
# the full prefix.
check-api-paths:
	@PREFIX="$(API_PREFIX)"; \
	BAD=$$(grep -rEo '(get|post|put|delete|patch): "/[^"]*"' $(PROTO_DIR)/*.proto \
	    | grep -v ": \"$$PREFIX"); \
	if [ -n "$$BAD" ]; then \
	    echo "ERROR: proto paths missing api_prefix '$$PREFIX':"; \
	    echo "$$BAD"; \
	    exit 1; \
	fi; \
	echo "OK: all proto HTTP paths start with '$$PREFIX'"

build:
	@mkdir -p bin
	go build -o $(BINARY) .

test:
	go test -v ./...

# test-integration runs the full suite including testcontainers-backed
# integration tests (-tags=integration). Requires Docker.
test-integration:
	DOCKER_HOST=$$(docker context inspect --format '{{.Endpoints.docker.Host}}') \
	    TESTCONTAINERS_RYUK_DISABLED=true \
	    go test -v -tags=integration ./...

# ── Lint ──────────────────────────────────────────────────────────────────────
# golangci-lint config lives in .golangci.yml.

# Install golangci-lint if not present. Uses brew (the cluster CI runner image
# can install via `go install` instead — adjust there if needed).
lint-install:
	@which golangci-lint >/dev/null 2>&1 || \
	    (echo "Installing golangci-lint…" && brew install golangci-lint)

# Run all enabled linters across the whole codebase.
lint: lint-install
	golangci-lint run ./...

# Run linters only on lines changed since the last commit. Use this from a
# pre-commit hook to gate only on newly introduced issues.
lint-new: lint-install
	golangci-lint run --new-from-rev=HEAD ./...

# Auto-fix formatting and simple issues.
lint-fix: lint-install
	golangci-lint run --fix ./...

# Point git at the in-repo .githooks/ directory. One-time per clone; survives
# branch switches but does not propagate to other clones — every contributor
# runs this once. `git commit --no-verify` skips the hook for a single commit.
hooks-install:
	git config core.hooksPath .githooks
	@echo "Pre-commit hook installed. Skip with: git commit --no-verify"

# ── Coverage ──────────────────────────────────────────────────────────────────
# Coverage floors are configured in project.yaml (coverage_global_min,
# coverage_package_min, coverage_exempt_patterns). Defaults are 0.0 for this
# sample repo — raise them as a real test suite is added.

COVERAGE_DIR     := coverage
GO_COVER_OUT     := $(COVERAGE_DIR)/go-coverage.out
GO_COVER_HTML    := $(COVERAGE_DIR)/go-coverage.html
GO_COVER_SUMMARY := $(COVERAGE_DIR)/go-coverage-summary.txt
GO_COVER_PER_PKG := $(COVERAGE_DIR)/go-package-coverage.txt

# Run the test suite with coverage profiling, then render summary + HTML.
# Excludes the generated pb/ package — its statements would dominate the
# numerator without exercising any real logic.
coverage-go:
	@mkdir -p $(COVERAGE_DIR)
	@PKGS=$$(go list ./... | grep -v '/pb$$'); \
	    go test -count=1 -covermode=atomic -coverprofile=$(GO_COVER_OUT) $$PKGS \
	      | tee $(GO_COVER_PER_PKG).raw
	@grep -E '^ok\s.+coverage: [0-9.]+%' $(GO_COVER_PER_PKG).raw > $(GO_COVER_PER_PKG) || true
	@rm -f $(GO_COVER_PER_PKG).raw
	go tool cover -html=$(GO_COVER_OUT) -o $(GO_COVER_HTML)
	go tool cover -func=$(GO_COVER_OUT) > $(GO_COVER_SUMMARY)

# Enforce the global and per-package coverage floors from project.yaml.
# Mirror this in CI so local + CI fail for the same reasons. Floors of 0.0
# mean "anything passes" — useful as a sample-repo default.
coverage-check: coverage-go
	@global=$$(awk '/^total:/ {gsub("%",""); print $$3}' $(GO_COVER_SUMMARY)); \
	awk -v pct="$$global" -v min="$(GO_COVERAGE_GLOBAL_MIN)" 'BEGIN { \
	  if (pct + 0 < min + 0) { printf "FAIL: global coverage %s%% < %s%% floor\n", pct, min; exit 1 } \
	  printf "OK: global coverage %s%% >= %s%% floor\n", pct, min \
	}'
	@exempt='$(GO_COVERAGE_EXEMPT_PATTERNS)'; \
	fail=0; \
	while IFS= read -r line; do \
	  pkg=$$(echo "$$line" | awk '{print $$2}'); \
	  pct=$$(echo "$$line" | sed -E 's/.*coverage: ([0-9.]+)% of statements.*/\1/'); \
	  if [ -n "$$exempt" ] && echo "$$pkg" | grep -qE "$$exempt"; then \
	    printf "  exempt: %-50s %s%%\n" "$$pkg" "$$pct"; continue; \
	  fi; \
	  awk -v pkg="$$pkg" -v pct="$$pct" -v min="$(GO_COVERAGE_PACKAGE_MIN)" 'BEGIN { \
	    if (pct + 0 < min + 0) { printf "  FAIL:   %-50s %s%% < %s%% floor\n", pkg, pct, min; exit 1 } \
	    printf "  ok:     %-50s %s%%\n", pkg, pct \
	  }' || fail=1; \
	done < $(GO_COVER_PER_PKG); \
	if [ "$$fail" = "1" ]; then \
	  echo; echo "One or more packages are below the $(GO_COVERAGE_PACKAGE_MIN)% per-package floor."; \
	  exit 1; \
	fi

# Convenience alias. Frontend coverage isn't wired up yet (no vitest setup
# in web/) — add a coverage-frontend target when those tests land.
coverage: coverage-go

docker-build:
	docker buildx build --platform linux/amd64,linux/arm64 \
	    -t $(PUSH_IMAGE):$(VERSION)-$(GIT_SHA) \
	    -t $(PUSH_IMAGE):latest \
	    --build-arg VERSION=$(VERSION)-$(GIT_SHA) \
	    --push .
	$(SED_INPLACE) "s|$(IMAGE):.*|$(IMAGE):$(VERSION)-$(GIT_SHA)|" k8s/deployment.yaml

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
	    --build-arg VITE_GOOGLE_CLIENT_ID=$(GOOGLE_CLIENT_ID) \
	    --push \
	    web/
	$(SED_INPLACE) "s|$(WEB_IMAGE):.*|$(WEB_IMAGE):$(VERSION)-$(GIT_SHA)|" k8s/web-deployment.yaml

web-deploy:
	kubectl apply -f k8s/web-deployment.yaml

# kong-deploy refreshes the proto configmaps, applies the Ingress/plugin
# manifest, upgrades the Kong Helm release with the latest values, and rolls
# the gateway so the new configmap mounts take effect.
#
# This is an expensive operation (helm upgrade + rollout can take several
# minutes). Run only when proto annotations, Kong config, or kong-values.yaml
# actually change — not on every backend push.
#
# If you later add a proto that imports google.protobuf.* well-known types,
# add a `protobuf-wkt-protos` configmap (e.g. wrappers.proto, empty.proto)
# alongside googleapis-protos and mount it in k8s/templates/kong-values.yaml.
kong-deploy:
	helm repo add kong https://charts.konghq.com 2>/dev/null || true
	helm repo update kong
	# Bundle every .proto in $(PROTO_DIR) into the configmap so Kong's
	# grpc-gateway plugin can resolve cross-file imports (the umbrella
	# $(PROJECT_NAME).proto imports the others). Auto-grows as new protos
	# are added — no more hand-maintained --from-file list.
	kubectl create configmap $(PROJECT_NAME)-proto \
	    $(foreach p,$(wildcard $(PROTO_DIR)/*.proto),--from-file=$(notdir $(p))=$(p)) \
	    --namespace kong \
	    --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap googleapis-protos \
	    --from-file=annotations.proto=third_party/google/api/annotations.proto \
	    --from-file=http.proto=third_party/google/api/http.proto \
	    --namespace kong \
	    --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/kong.yaml
	helm upgrade kong kong/ingress --namespace kong --values k8s/kong-values.yaml
	kubectl rollout restart deployment/kong-gateway -n kong
	kubectl rollout status deployment/kong-gateway -n kong

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
	@printf '# Base environment — loaded in all Vite modes (dev and production build).\n# Values here are baked into the JS bundle at build time.\n#\n# This file is auto-updated by `make generate-k8s` from project.yaml.\n# Do not edit by hand; change values in project.yaml instead.\nVITE_GITHUB_REPO=$(GITHUB_REPO)\nVITE_GOOGLE_CLIENT_ID=$(GOOGLE_CLIENT_ID)\n' > web/.env
	@echo "  project.yaml -> web/.env"
	@echo "Done. Review changes with 'git diff' and commit if correct."
	@echo "Note: docker-build will re-pin the image tags in deployment.yaml and web-deployment.yaml."

# Render the self-hosted GitHub Actions runner manifest. Opt-in: templates
# under k8s/templates/optional/ are deliberately excluded from `generate-k8s`,
# so the runner is never deployed by accident. Run this only when you actually
# want a runner in the cluster — see k8s/templates/optional/runner.yaml for
# the full setup sequence.
generate-runner:
	@command -v envsubst >/dev/null 2>&1 || \
	    { echo "envsubst not found. Install with: brew install gettext"; exit 1; }
	@export \
	    PROJECT_NAME="$(PROJECT_NAME)" \
	    NAMESPACE="$(NAMESPACE)" \
	    REGISTRY_LAN="$(REGISTRY_LAN)" \
	    REGISTRY_TS="$(REGISTRY_TS)" \
	    GITHUB_REPO="$(GITHUB_REPO)"; \
	envsubst < k8s/templates/optional/runner.yaml > k8s/runner.yaml
	@echo "  k8s/templates/optional/runner.yaml -> k8s/runner.yaml"
	@echo "Next steps:"
	@echo "  1. make runner-build"
	@echo "  2. kubectl create secret generic github-runner-secret -n $(NAMESPACE) --from-literal=github_token=<PAT>"
	@echo "  3. make runner-deploy"

# ── CI Runner ─────────────────────────────────────────────────────────────────
# Build and push the runner image to the cluster registry. The cluster registry
# serves plain HTTP, so BuildKit needs an explicit insecure entry for both the
# LAN and Tailscale IPs. The sample-grpc-insecure builder is created on first
# use and reused thereafter.
RUNNER_IMAGE := $(REGISTRY_TS)/github-runner:latest

runner-builder:
	@if ! docker buildx inspect sample-grpc-insecure >/dev/null 2>&1; then \
	    echo "Creating sample-grpc-insecure buildx builder…"; \
	    TMP=$$(mktemp); \
	    printf '[registry."%s"]\n  http = true\n  insecure = true\n[registry."%s"]\n  http = true\n  insecure = true\n' \
	        "$(REGISTRY_LAN)" "$(REGISTRY_TS)" > $$TMP; \
	    docker buildx create --name sample-grpc-insecure --driver docker-container --config $$TMP; \
	    rm -f $$TMP; \
	fi

runner-build: runner-builder
	docker buildx build --builder sample-grpc-insecure --platform linux/amd64 \
	    -t $(RUNNER_IMAGE) \
	    --push \
	    docker/runner/

# Apply the runner Deployment + RBAC. Requires `make generate-runner` first
# so k8s/runner.yaml exists.
runner-deploy:
	@[ -f k8s/runner.yaml ] || { echo "k8s/runner.yaml missing — run 'make generate-runner' first"; exit 1; }
	kubectl apply -f k8s/runner.yaml

loadtest:
	go run ./cmd/loadtest -addr $(GRPC_ADDR) -concurrency 20 -duration 30s

db-cleanup:
	kubectl exec -n $(NAMESPACE) \
	    $$(kubectl get pod -n $(NAMESPACE) -l cnpg.io/cluster=$(PROJECT_NAME)-db \
	       -o jsonpath='{.items[0].metadata.name}') \
	    -- psql -U $(PROJECT_NAME) -c "TRUNCATE TABLE echo_requests;"

# ── Registry ──────────────────────────────────────────────────────────────────
# Helpers for inspecting and trimming the in-cluster container registry.

# registry-show lists every repository and tag in the registry, annotating
# the tags currently referenced by a k8s deployment with "<- active".
registry-show:
	@set -e; \
	REGISTRY="$(REGISTRY_LAN)"; \
	BE_TAG=$$(grep -oE '$(IMAGE_NAME):[^ ]+' k8s/deployment.yaml | head -1 | cut -d: -f2); \
	WEB_TAG=$$(grep -oE '$(WEB_IMAGE_NAME):[^ ]+' k8s/web-deployment.yaml | head -1 | cut -d: -f2); \
	REPOS=$$(curl -sf "http://$$REGISTRY/v2/_catalog" \
	    | python3 -c "import sys,json; d=json.load(sys.stdin); [print(r) for r in d.get('repositories') or []]"); \
	for REPO in $$REPOS; do \
	    echo "$$REPO"; \
	    TAGS=$$(curl -sf "http://$$REGISTRY/v2/$$REPO/tags/list" \
	        | python3 -c "import sys,json; d=json.load(sys.stdin); [print(t) for t in sorted(d.get('tags') or [])]" \
	        2>/dev/null || true); \
	    for TAG in $$TAGS; do \
	        ACTIVE=""; \
	        if [ "$$REPO:$$TAG" = "$(IMAGE_NAME):$$BE_TAG" ] || \
	           [ "$$REPO:$$TAG" = "$(WEB_IMAGE_NAME):$$WEB_TAG" ]; then \
	            ACTIVE=" <- active"; \
	        fi; \
	        echo "  $$TAG$$ACTIVE"; \
	    done; \
	done

# registry-prune deletes every image tag that is not "latest" or the tag
# currently referenced by a k8s deployment, then runs garbage collection
# inside the registry pod to reclaim disk space.
#
# Prerequisites: REGISTRY_STORAGE_DELETE_ENABLED=true must be set on the
# registry container (already present in k8s/templates/registry.yaml).
registry-prune:
	@echo "=== Pruning stale images from registry ==="
	@set -e; \
	REGISTRY="$(REGISTRY_LAN)"; \
	BE_TAG=$$(grep -oE '$(IMAGE_NAME):[^ ]+' k8s/deployment.yaml | head -1 | cut -d: -f2); \
	WEB_TAG=$$(grep -oE '$(WEB_IMAGE_NAME):[^ ]+' k8s/web-deployment.yaml | head -1 | cut -d: -f2); \
	echo "Active tags — backend: $$BE_TAG  web: $$WEB_TAG"; \
	for ENTRY in "$(IMAGE_NAME):$$BE_TAG" "$(WEB_IMAGE_NAME):$$WEB_TAG"; do \
	    REPO=$$(echo "$$ENTRY" | cut -d: -f1); \
	    KEEP=$$(echo "$$ENTRY" | cut -d: -f2); \
	    echo "--- $$REPO (keeping: latest, $$KEEP) ---"; \
	    TAGS=$$(curl -sf "http://$$REGISTRY/v2/$$REPO/tags/list" \
	        | python3 -c "import sys,json; d=json.load(sys.stdin); [print(t) for t in d.get('tags') or []]" \
	        2>/dev/null || true); \
	    for TAG in $$TAGS; do \
	        if [ "$$TAG" = "latest" ] || [ "$$TAG" = "$$KEEP" ]; then \
	            echo "  keep    $$TAG"; continue; \
	        fi; \
	        DIGEST=$$(curl -sf -I \
	            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
	            "http://$$REGISTRY/v2/$$REPO/manifests/$$TAG" \
	            | grep -i docker-content-digest | awk '{print $$2}' | tr -d '\r\n'); \
	        if [ -n "$$DIGEST" ]; then \
	            curl -sf -X DELETE "http://$$REGISTRY/v2/$$REPO/manifests/$$DIGEST" \
	                && echo "  deleted $$TAG" \
	                || echo "  failed  $$TAG (registry may not have delete enabled)"; \
	        fi; \
	    done; \
	done
	@echo "=== Running garbage collection in registry pod ==="
	kubectl exec -n registry-system deploy/registry -- \
	    registry garbage-collect /etc/docker/registry/config.yml --delete-untagged
	@echo "=== Done ==="

clean:
	rm -rf bin/
	rm -f loadtest
