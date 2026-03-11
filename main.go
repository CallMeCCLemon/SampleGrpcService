package main

import (
	"context"
	"fmt"
	"log"
	"net"

	pb "SampleGrpcProject/pb"

	"google.golang.org/grpc"
)

const port = 50051

type server struct {
	pb.UnimplementedGreeterServer
}

func (s *server) SayHello(_ context.Context, req *pb.HelloRequest) (*pb.HelloReply, error) {
	log.Printf("SayHello called with name: %s", req.Name)
	return &pb.HelloReply{Message: "Hello, " + req.Name + "!"}, nil
}

func (s *server) SayGoodbye(_ context.Context, req *pb.GoodbyeRequest) (*pb.GoodbyeReply, error) {
	log.Printf("SayGoodbye called with name: %s", req.Name)
	return &pb.GoodbyeReply{Message: "Goodbye, " + req.Name + "!"}, nil
}

func main() {
	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	s := grpc.NewServer()
	pb.RegisterGreeterServer(s, &server{})

	log.Printf("gRPC server listening on port %d", port)
	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
