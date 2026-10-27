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
# In-cluster CI runners cannot route Tailscale IPs, so pushes from GitHub
# Actions go over the LAN. Override with `make docker-build PUSH_REGISTRY=...`.
PUSH_REGISTRY  ?= $(if $(GITHUB_ACTIONS),$(REGISTRY_LAN),$(REGISTRY_TS))

IMAGE          := $(REGISTRY_LAN)/$(IMAGE_NAME)
PUSH_IMAGE     := $(PUSH_REGISTRY)/$(IMAGE_NAME)
WEB_IMAGE      := $(REGISTRY_LAN)/$(WEB_IMAGE_NAME)
WEB_PUSH_IMAGE := $(PUSH_REGISTRY)/$(WEB_IMAGE_NAME)

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

# ── Targets ───────────────────────────────────────────────────────────────────
.PHONY: all build test test-integration vet-integration proto web-proto check-api-paths \
        lint lint-install lint-new lint-fix web-build web-lint \
        coverage coverage-go coverage-check \
        ci-builder docker-build docker-run deploy deploy-all release k8s-rollout \
        web-docker-build web-deploy \
        kong-deploy kong-register generate-k8s init \
        registry-show registry-prune \
        hooks-install help \
        loadtest db-cleanup \
        run clean

# help prints every documented target. Targets are documented by appending
# `## <description>` after their colon — `make help` greps those out.
help:  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

all: proto build  ## Regenerate proto + build Go binary

# init turns a fresh copy of the template into a new project: rewrites
# project.yaml, renames the umbrella proto and Go module, re-renders k8s/,
# regenerates stubs, and enables CI. Refuses to run twice.
init:  ## Rename the template for a new project: make init NAME=foo REPO=https://github.com/org/foo
	@test -n "$(NAME)" || { echo 'NAME=<project_name> is required (lowercase, no hyphens)'; exit 1; }
	@test -n "$(REPO)" || { echo 'REPO=<github url> is required'; exit 1; }
	scripts/init-project.sh "$(NAME)" "$(REPO)" "$(MODULE)"

proto:  ## Regenerate Go gRPC stubs in pb/
	protoc --go_out=$(PB_DIR) --go_opt=paths=source_relative \
	       --go-grpc_out=$(PB_DIR) --go-grpc_opt=paths=source_relative \
	       -I $(PROTO_DIR) -I third_party \
	       $(PROTO_DIR)/*.proto

web-proto:  ## Regenerate TypeScript gRPC stubs in web/src/generated/
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
check-api-paths:  ## Verify every proto HTTP annotation starts with api_prefix
	@PREFIX="$(API_PREFIX)"; \
	BAD=$$(grep -rEo '(get|post|put|delete|patch): "/[^"]*"' $(PROTO_DIR)/*.proto \
	    | grep -v ": \"$$PREFIX"); \
	if [ -n "$$BAD" ]; then \
	    echo "ERROR: proto paths missing api_prefix '$$PREFIX':"; \
	    echo "$$BAD"; \
	    exit 1; \
	fi; \
	echo "OK: all proto HTTP paths start with '$$PREFIX'"

build:  ## Compile bin/server and verify every package + cmd/* tool compiles
	@mkdir -p bin
	go build -o $(BINARY) .
	go build ./...

test:  ## Run fast Go tests (sqlmock + interceptor matrix, no Docker)
	go test -v ./...

# INTEGRATION_PKGS is every package holding an integration-tagged test file,
# discovered rather than listed so a new one cannot be silently left out.
# Running ./... with the tag would re-run the whole fast suite a second time.
INTEGRATION_PKGS = $(shell grep -rl '^//go:build integration' --include='*_test.go' . \
	| xargs -n1 dirname | sort -u)

# test-integration runs the testcontainers-backed tests. Requires Docker.
# -count=1 because the test cache cannot see the database container, so an
# unchanged binary would otherwise return a cached pass without starting one.
# Set VERBOSE=1 for -v output.
test-integration:  ## Run the integration-tagged tests (requires Docker)
	@test -n "$(INTEGRATION_PKGS)" || { echo "no integration-tagged packages found"; exit 1; }
	DOCKER_HOST=$$(docker context inspect --format '{{.Endpoints.docker.Host}}') \
	    TESTCONTAINERS_RYUK_DISABLED=true \
	    go test -count=1 $(if $(VERBOSE),-v,) -tags=integration $(INTEGRATION_PKGS)

# vet-integration type-checks the integration-tagged test files that `make
# test` and lint never compile, so a stale fake fails in seconds without Docker.
vet-integration:  ## Compile-check integration-tagged test files (no Docker)
	go vet -tags=integration ./...

# ── Lint ──────────────────────────────────────────────────────────────────────
# golangci-lint config lives in .golangci.yml.

# Install golangci-lint if not present: brew on dev machines, `go install` on
# the CI runner (no brew there). GOLANGCI resolves the binary in either
# location because the runner does not put GOPATH/bin on PATH.
GOLANGCI_LINT_VERSION ?= v2.11.4
GOLANGCI := $(shell which golangci-lint 2>/dev/null || echo "$$(go env GOPATH)/bin/golangci-lint")
lint-install:
	@test -x "$(GOLANGCI)" || { \
	    echo "Installing golangci-lint…"; \
	    if which brew >/dev/null 2>&1; then \
	        brew install golangci-lint; \
	    else \
	        go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION); \
	    fi; \
	}

# Run all enabled linters across the whole codebase.
lint: lint-install  ## Run all enabled linters across the codebase
	$(GOLANGCI) run ./...

# Run linters only on lines changed since the last commit. Use this from a
# pre-commit hook to gate only on newly introduced issues.
lint-new: lint-install  ## Lint only newly changed lines (used by the pre-commit hook)
	$(GOLANGCI) run --new-from-rev=HEAD ./...

# Auto-fix formatting and simple issues.
lint-fix: lint-install  ## Auto-fix formatting + simple lint issues
	$(GOLANGCI) run --fix ./...

# `npm --prefix web` runs the script with cwd=web/ without changing the
# caller's directory.
web-build:  ## Build the frontend (tsc -b && vite build), same step as the web image
	npm --prefix web run build

web-lint:  ## Run eslint over web/
	npm --prefix web run lint

# Point git at the in-repo .githooks/ directory. One-time per clone; survives
# branch switches but does not propagate to other clones — every contributor
# runs this once. `git commit --no-verify` skips the hook for a single commit.
hooks-install:  ## Install the pre-commit hook for this clone (one-time)
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
coverage-go:  ## Generate coverage/go-coverage.{out,html,txt} + per-package summary
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
coverage-check: coverage-go  ## Enforce global + per-package coverage floors from project.yaml
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
coverage: coverage-go  ## Alias for coverage-go (frontend coverage TBD)

# ci-builder creates the buildx builder CI pushes through. The cluster registry
# serves plain HTTP, so BuildKit needs an explicit insecure entry for it.
ci-builder:
	@TMP=$$(mktemp); \
	printf '[registry."%s"]\n  http = true\n  insecure = true\n' "$(REGISTRY_LAN)" > $$TMP; \
	docker buildx rm builder 2>/dev/null || true; \
	docker buildx create --use --name builder --driver docker-container --config $$TMP; \
	rm -f $$TMP

# Image strategy: docker-build pushes both the SHA-pinned tag and :latest.
# k8s/deployment.yaml stays at :latest as a fresh-cluster bootstrap template
# and is never rewritten; `make k8s-rollout` moves the live deployment to the
# SHA tag with `kubectl set image`, which is the deploy source of truth.
docker-build:  ## Buildx multi-platform build + push of the backend image
	docker buildx build --platform linux/amd64,linux/arm64 \
	    -t $(PUSH_IMAGE):$(VERSION)-$(GIT_SHA) \
	    -t $(PUSH_IMAGE):latest \
	    --build-arg VERSION=$(VERSION)-$(GIT_SHA) \
	    --push .

docker-run:  ## Run the backend image locally
	docker run --rm -p $(PORT):$(PORT) $(IMAGE)

run:  ## Run the gRPC server locally (requires DATABASE_URL)
	go run .

deploy:  ## kubectl apply the backend deployment (bootstrap; use k8s-rollout to ship code)
	kubectl apply -f k8s/deployment.yaml

# Applies this project's manifests in dependency order: deployment.yaml first
# (creates the namespace), then everything else. Shared platform pieces (Kong
# Helm release, registry, CI runner, CNPG operator) are owned by the platform
# repo and deliberately not applied from here.
deploy-all:  ## Apply every project k8s manifest in dependency order
	kubectl apply -f k8s/deployment.yaml
	kubectl apply \
	    -f k8s/postgres.yaml \
	    -f k8s/cloudflared.yaml \
	    -f k8s/kong.yaml \
	    -f k8s/web-deployment.yaml

# GIT_SHA is baked into the web image so every commit gets a distinct manifest
# digest. Without it, commits that do not touch web/ produce identical digests,
# and deleting one stale tag in registry-prune would dangle the live one.
web-docker-build:  ## Buildx multi-platform build + push of the web image
	docker buildx build --platform linux/amd64,linux/arm64 \
	    -t $(WEB_PUSH_IMAGE):$(VERSION)-$(GIT_SHA) \
	    -t $(WEB_PUSH_IMAGE):latest \
	    --build-arg VITE_GITHUB_REPO=$(GITHUB_REPO) \
	    --build-arg VITE_GOOGLE_CLIENT_ID=$(GOOGLE_CLIENT_ID) \
	    --build-arg GIT_SHA=$(VERSION)-$(GIT_SHA) \
	    --push \
	    web/

web-deploy:  ## kubectl apply the web deployment (bootstrap; use k8s-rollout to ship code)
	kubectl apply -f k8s/web-deployment.yaml

# release builds both images in parallel and rolls them out. Kong is not
# included; run `make kong-deploy` only when proto HTTP routes change.
release:  ## Build + push both images, then k8s-rollout
	$(MAKE) docker-build & $(MAKE) web-docker-build & wait
	$(MAKE) k8s-rollout

# k8s-rollout points both deployments at the current VERSION-SHA tag and waits
# for ready. Each commit's tag is unique, so `set image` always produces a real
# spec change. A deployment that does not exist yet is created from its
# :latest manifest first so the first CI run on a new project succeeds.
k8s-rollout:  ## Update both deployments to the SHA-tagged image and wait for ready
	kubectl get deployment/$(PROJECT_NAME) -n $(NAMESPACE) >/dev/null 2>&1 || kubectl apply -f k8s/deployment.yaml
	kubectl get deployment/$(PROJECT_NAME)-web -n $(NAMESPACE) >/dev/null 2>&1 || kubectl apply -f k8s/web-deployment.yaml
	kubectl set image deployment/$(PROJECT_NAME) \
	    $(PROJECT_NAME)=$(IMAGE):$(VERSION)-$(GIT_SHA) \
	    -n $(NAMESPACE)
	kubectl set image deployment/$(PROJECT_NAME)-web \
	    $(PROJECT_NAME)-web=$(WEB_IMAGE):$(VERSION)-$(GIT_SHA) \
	    -n $(NAMESPACE)
	kubectl rollout status deployment/$(PROJECT_NAME) -n $(NAMESPACE) --timeout=120s
	kubectl rollout status deployment/$(PROJECT_NAME)-web -n $(NAMESPACE) --timeout=120s

# kong-deploy refreshes this project's proto configmap, applies its
# KongPlugin + Ingress, and restarts the gateway only when the protos changed.
#
# The Kong Helm release and kong-values.yaml are shared platform
# infrastructure (one gateway for every project) and are NOT touched here:
# running `helm upgrade kong` from a project raced with other projects and
# overwrote their mounts. The platform's kong-values.yaml mounts the
# <project>-proto configmap at /etc/kong/protos/<project>/; see
# `make kong-register` for the block a new project adds there.
#
# The grpc-gateway plugin reads the proto into memory at init and does not
# notice configmap updates, so new HTTP routes 400 with "Unknown path" until
# the gateway restarts. Skipping the restart when nothing changed keeps open
# WebSockets on every project alive.
kong-deploy:  ## Refresh <project>-proto configmap + apply Ingress; restart Kong only if protos changed
	@set -e; \
	echo "=== Applying $(PROJECT_NAME)-proto configmap ==="; \
	CM_OUT=$$(kubectl create configmap $(PROJECT_NAME)-proto \
	    $(foreach p,$(wildcard $(PROTO_DIR)/*.proto),--from-file=$(notdir $(p))=$(p)) \
	    --namespace kong \
	    --dry-run=client -o yaml | kubectl apply -f -); \
	echo "$$CM_OUT"; \
	kubectl apply -f k8s/kong.yaml; \
	if echo "$$CM_OUT" | grep -qE "configured|created"; then \
	    echo "=== Proto configmap changed; restarting kong-gateway so grpc-gateway reloads it ==="; \
	    kubectl rollout restart deployment/kong-gateway -n kong; \
	    kubectl rollout status  deployment/kong-gateway -n kong --timeout=120s; \
	else \
	    echo "=== Proto configmap unchanged; skipping kong-gateway restart ==="; \
	fi

# kong-register prints the volume + mount entries a new project needs in the
# platform repo's k8s/templates/kong-values.yaml. Paste them in there, then run
# that repo's `make generate-k8s && make kong-deploy` once.
kong-register:  ## Print the kong-values.yaml block that mounts this project's protos
	@printf '%s\n' \
	    '# under gateway.deployment.userDefinedVolumes:' \
	    '      - name: $(PROJECT_NAME)-protos' \
	    '        configMap:' \
	    '          name: $(PROJECT_NAME)-proto' \
	    '          optional: true' \
	    '' \
	    '# under gateway.deployment.userDefinedVolumeMounts:' \
	    '      - name: $(PROJECT_NAME)-protos' \
	    '        mountPath: /etc/kong/protos/$(PROJECT_NAME)' \
	    '        readOnly: true' \
	    '      - name: googleapis-protos' \
	    '        mountPath: /etc/kong/protos/$(PROJECT_NAME)/google/api' \
	    '        readOnly: true' \
	    '      - name: protobuf-wkt-protos' \
	    '        mountPath: /etc/kong/protos/$(PROJECT_NAME)/google/protobuf' \
	    '        readOnly: true'

# Render k8s/templates/*.yaml → k8s/*.yaml using the values in project.yaml.
# Requires envsubst (macOS: brew install gettext).
# Run this after editing project.yaml, then review `git diff k8s/` and commit.
generate-k8s:  ## Render k8s/templates/*.yaml -> k8s/*.yaml from project.yaml
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
	@printf '# Base environment — loaded in all Vite modes (dev and production build).\n# Values here are baked into the JS bundle at build time.\n#\n# This file is auto-updated by `make generate-k8s` from project.yaml.\n# Do not edit by hand; change values in project.yaml instead.\nVITE_GITHUB_REPO=$(GITHUB_REPO)\nVITE_GOOGLE_CLIENT_ID=$(GOOGLE_CLIENT_ID)\n# Read by vite.config.ts only (no VITE_ prefix, so not baked into the bundle).\nPUBLIC_DOMAIN=$(PUBLIC_DOMAIN)\n' > web/.env
	@echo "  project.yaml -> web/.env"
	@echo "Done. Review changes with 'git diff' and commit if correct."
	@echo "Image tags in deployment.yaml / web-deployment.yaml stay at :latest; the"
	@echo "live tag is set per commit by 'make k8s-rollout' via kubectl set image."

# CI runs on the shared self-hosted runner registered to the GitHub org (labels
# `self-hosted, k8s`), managed by the platform repo. This project does not
# stand up its own runner.

loadtest:  ## Hammer the gRPC server: 20 connections for 30s
	go run ./cmd/loadtest -addr $(GRPC_ADDR) -concurrency 20 -duration 30s

db-cleanup:  ## TRUNCATE the echo_requests table on the cluster
	kubectl exec -n $(NAMESPACE) \
	    $$(kubectl get pod -n $(NAMESPACE) -l cnpg.io/cluster=$(PROJECT_NAME)-db \
	       -o jsonpath='{.items[0].metadata.name}') \
	    -- psql -U $(PROJECT_NAME) -c "TRUNCATE TABLE echo_requests;"

# ── Registry ──────────────────────────────────────────────────────────────────
# Helpers for inspecting and trimming the in-cluster container registry. The
# registry is shared platform infrastructure (registry-system namespace); these
# targets only query and clean tags belonging to this project's images.

# registry-show lists every repository and tag in the registry, annotating
# the tags the live deployments are running with "<- active".
registry-show:  ## List repos/tags in the cluster registry; flag live ones
	@set -e; \
	REGISTRY="$(REGISTRY_LAN)"; \
	livetag() { kubectl get deploy "$$1" -n $(NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | awk -F: '{print $$NF}'; }; \
	BE_TAG=$$(livetag $(PROJECT_NAME)); \
	WEB_TAG=$$(livetag $(PROJECT_NAME)-web); \
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

# registry-prune deletes this project's stale image tags (backend + web repos
# only; other projects' repos are never touched). The tag to keep is read from
# the running Deployment, not the committed manifest, because k8s-rollout
# moves the live tag without editing the YAML. A repo with no live Deployment
# is skipped rather than mass-deleted.
#
# Deleting by digest removes the manifest for every tag that points at it, so
# a tag is skipped when its digest matches `latest`, the live tag, or any other
# remaining tag.
#
# Tag deletes do not free disk. Blob reclamation is a registry-wide
# garbage-collect pass owned by the platform repo and is not run from here.
#
# Prerequisites: REGISTRY_STORAGE_DELETE_ENABLED=true on the registry container.
registry-prune:  ## Delete this project's stale image tags (keep latest + live-deployed)
	@echo "=== Pruning stale images from registry ==="
	@set -e; \
	REGISTRY="$(REGISTRY_LAN)"; \
	livetag() { kubectl get deploy "$$1" -n $(NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | awk -F: '{print $$NF}'; }; \
	digest() { curl -sf -I -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json" "http://$$REGISTRY/v2/$$1/manifests/$$2" 2>/dev/null | grep -i docker-content-digest | awk '{print $$2}' | tr -d '\r\n'; }; \
	for ENTRY in \
	    "$(IMAGE_NAME):$$(livetag $(PROJECT_NAME))" \
	    "$(WEB_IMAGE_NAME):$$(livetag $(PROJECT_NAME)-web)"; do \
	    REPO=$$(echo "$$ENTRY" | cut -d: -f1); \
	    KEEP=$$(echo "$$ENTRY" | cut -d: -f2); \
	    if [ -z "$$KEEP" ]; then echo "--- $$REPO (no live deployment; skipping) ---"; continue; fi; \
	    KEEP_DIGESTS=$$(printf "%s\n%s\n" "$$(digest $$REPO latest)" "$$(digest $$REPO $$KEEP)" | grep -v '^$$' | sort -u); \
	    echo "--- $$REPO (keeping: latest, $$KEEP) ---"; \
	    TAGS=$$(curl -sf "http://$$REGISTRY/v2/$$REPO/tags/list" \
	        | python3 -c "import sys,json; d=json.load(sys.stdin); [print(t) for t in d.get('tags') or []]" \
	        2>/dev/null || true); \
	    DIGEST_INDEX=$$(mktemp); \
	    for T in $$TAGS; do \
	        D=$$(digest $$REPO $$T); \
	        if [ -n "$$D" ]; then echo "$$D $$T" >> $$DIGEST_INDEX; fi; \
	    done; \
	    for TAG in $$TAGS; do \
	        if [ "$$TAG" = "latest" ] || [ "$$TAG" = "$$KEEP" ]; then \
	            echo "  keep    $$TAG"; continue; \
	        fi; \
	        D=$$(digest $$REPO $$TAG); \
	        if [ -n "$$D" ] && echo "$$KEEP_DIGESTS" | grep -qFx "$$D"; then \
	            echo "  keep    $$TAG (shares manifest digest with a live tag)"; continue; \
	        fi; \
	        if [ -n "$$D" ]; then \
	            SHARERS=$$(awk -v d="$$D" '$$1==d {print $$2}' $$DIGEST_INDEX | grep -vFx "$$TAG" || true); \
	            if [ -n "$$SHARERS" ]; then \
	                echo "  skip    $$TAG (digest shared by: $$(echo $$SHARERS | tr '\n' ' '))"; \
	                continue; \
	            fi; \
	            curl -sf -X DELETE "http://$$REGISTRY/v2/$$REPO/manifests/$$D" \
	                && echo "  deleted $$TAG" \
	                || echo "  failed  $$TAG (registry may not have delete enabled)"; \
	        fi; \
	    done; \
	    rm -f $$DIGEST_INDEX; \
	done
	@echo "=== Done (tag deletes only; registry GC is owned by the platform repo) ==="

clean:  ## Remove bin/ and the legacy loadtest binary
	rm -rf bin/
	rm -f loadtest
