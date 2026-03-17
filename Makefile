BINARY         := server
# LAN registry address — used in deployment.yaml so k8s nodes pull over LAN
REGISTRY_LAN   := 192.168.1.110:32000
# Tailscale registry address — used for pushing from the dev machine
REGISTRY_TS    := 100.69.236.43:32000
IMAGE          := $(REGISTRY_LAN)/sample-grpc
PUSH_IMAGE     := $(REGISTRY_TS)/sample-grpc
WEB_IMAGE      := $(REGISTRY_LAN)/sample-grpc-web
WEB_PUSH_IMAGE := $(REGISTRY_TS)/sample-grpc-web
PORT        := 50051
# gRPC NodePort for external tooling (grpcurl, loadtest) — override with: make GRPC_ADDR=<host>:<port>
GRPC_ADDR   := 192.168.1.110:30051
PROTO_DIR   := proto
PB_DIR      := pb
VERSION     := $(shell cat VERSION)
GIT_SHA     := $(shell git rev-parse --short HEAD)

.PHONY: all build test test-all proto docker-build docker-run deploy clean loadtest db-cleanup kong-deploy web-proto web-docker-build web-deploy

all: proto build

proto:
	protoc --go_out=$(PB_DIR) --go_opt=paths=source_relative \
	       --go-grpc_out=$(PB_DIR) --go-grpc_opt=paths=source_relative \
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
	kubectl set image deployment/greeter greeter=$(IMAGE):$(VERSION) -n grpc-demo

loadtest:
	go run ./cmd/loadtest -addr $(GRPC_ADDR) -concurrency 20 -duration 30s

kong-deploy:
	kubectl create configmap greeter-proto \
	    --from-file=greeter.proto=proto/greeter.proto \
	    --namespace kong \
	    --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap googleapis-protos \
	    --from-file=annotations.proto=third_party/google/api/annotations.proto \
	    --from-file=http.proto=third_party/google/api/http.proto \
	    --namespace kong \
	    --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/kong.yaml
	kubectl apply -f k8s/deployment.yaml

db-cleanup:
	kubectl exec -n grpc-demo \
	    $$(kubectl get pod -n grpc-demo -l cnpg.io/cluster=greeter-db -o jsonpath='{.items[0].metadata.name}') \
	    -- psql -U greeter -c "TRUNCATE TABLE hello_requests, goodbye_requests;"

web-docker-build:
	docker buildx build --platform linux/amd64,linux/arm64 \
	    -t $(WEB_PUSH_IMAGE):$(VERSION)-$(GIT_SHA) \
	    -t $(WEB_PUSH_IMAGE):latest \
	    --push \
	    web/
	sed -i '' "s|$(WEB_IMAGE):.*|$(WEB_IMAGE):$(VERSION)-$(GIT_SHA)|" k8s/web-deployment.yaml

web-deploy:
	kubectl apply -f k8s/web-deployment.yaml

web-proto:
	mkdir -p web/src/generated
	protoc \
	    --plugin=protoc-gen-ts_proto=web/node_modules/.bin/protoc-gen-ts_proto \
	    --ts_proto_out=web/src/generated \
	    --ts_proto_opt=esModuleInterop=true,outputServices=fetch-client,fetchType=native,constEnums=false \
	    -I $(PROTO_DIR) -I third_party \
	    $(PROTO_DIR)/*.proto

clean:
	rm -f $(BINARY)
	rm -f $(PB_DIR)/*.go
