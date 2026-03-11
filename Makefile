BINARY      := server
IMAGE       := localhost:32000/sample-grpc
PORT        := 50051
PROTO_DIR   := proto
PB_DIR      := pb

.PHONY: all build test proto docker-build docker-push docker-run deploy clean

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

docker-push:
	docker push $(IMAGE):latest

docker-run:
	docker run --rm -p $(PORT):$(PORT) $(IMAGE)

run:
	go run .

deploy:
	kubectl apply -f k8s/deployment.yaml

clean:
	rm -f $(BINARY)
	rm -f $(PB_DIR)/*.go
