BINARY      := server
IMAGE       := sample-grpc
PORT        := 50051
PROTO_DIR   := proto
PB_DIR      := pb

.PHONY: all build test proto docker-build docker-run deploy setup-registry clean

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
	docker build -t $(IMAGE) .

docker-run:
	docker run --rm -p $(PORT):$(PORT) $(IMAGE)

run:
	go run .

deploy:
	kubectl apply -f k8s/deployment.yaml

setup-registry:
	sudo ./scripts/setup-registry.sh

clean:
	rm -f $(BINARY)
	rm -f $(PB_DIR)/*.go
