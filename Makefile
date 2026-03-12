BINARY      := server
IMAGE       := 192.168.1.110:32000/sample-grpc
PORT        := 50051
PROTO_DIR   := proto
PB_DIR      := pb
VERSION     := $(shell cat VERSION)
GIT_SHA     := $(shell git rev-parse --short HEAD)

.PHONY: all build test proto docker-build docker-run deploy clean

all: proto build

proto:
	protoc --go_out=$(PB_DIR) --go_opt=paths=source_relative \
	       --go-grpc_out=$(PB_DIR) --go-grpc_opt=paths=source_relative \
	       -I $(PROTO_DIR) $(PROTO_DIR)/*.proto

build:
	go build -o $(BINARY) .

test:
	go test -v ./...

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

clean:
	rm -f $(BINARY)
	rm -f $(PB_DIR)/*.go
