BINARY      := server
IMAGE       := 192.168.1.110:32000/sample-grpc
PORT        := 50051
GRPC_ADDR   := 192.168.1.110:30051
PROTO_DIR   := proto
PB_DIR      := pb
VERSION     := $(shell cat VERSION)
GIT_SHA     := $(shell git rev-parse --short HEAD)

.PHONY: all build test test-all proto docker-build docker-run deploy clean loadtest db-cleanup kong-deploy

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
	    -t $(IMAGE):$(VERSION) \
	    -t $(IMAGE):latest \
	    --build-arg VERSION=$(VERSION)-$(GIT_SHA) \
	    --push .

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

clean:
	rm -f $(BINARY)
	rm -f $(PB_DIR)/*.go
