package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"time"

	"SampleGrpcProject/internal/logger"
	pb "SampleGrpcProject/pb"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"
)

const port = 50051

// version is injected at build time via -ldflags "-X main.version=<git-sha>".
var version = "dev"

type server struct {
	pb.UnimplementedGreeterServer
}

func (s *server) SayHello(_ context.Context, req *pb.HelloRequest) (*pb.HelloReply, error) {
	if req.Name == "" {
		slog.Warn("SayHello called with empty name")
	}
	return &pb.HelloReply{Message: "Hello, " + req.Name + "!"}, nil
}

func (s *server) SayGoodbye(_ context.Context, req *pb.GoodbyeRequest) (*pb.GoodbyeReply, error) {
	if req.Name == "" {
		slog.Warn("SayGoodbye called with empty name")
	}
	return &pb.GoodbyeReply{Message: "Goodbye, " + req.Name + "!"}, nil
}

// loggingInterceptor logs every unary RPC request and response.
func loggingInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
	start := time.Now()

	slog.Info("request received",
		"method", info.FullMethod,
		"request", fmt.Sprintf("%+v", req),
	)

	resp, err := handler(ctx, req)
	duration := time.Since(start)

	if err != nil {
		st, _ := status.FromError(err)
		if st.Code() == codes.Internal || st.Code() == codes.Unknown {
			slog.Error("request failed",
				"method", info.FullMethod,
				"code", st.Code().String(),
				"error", err,
				"duration", duration,
			)
		} else {
			slog.Warn("request completed with non-OK status",
				"method", info.FullMethod,
				"code", st.Code().String(),
				"error", err,
				"duration", duration,
			)
		}
		return nil, err
	}

	slog.Info("request completed",
		"method", info.FullMethod,
		"response", fmt.Sprintf("%+v", resp),
		"duration", duration,
	)
	return resp, nil
}

func main() {
	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		logger.Fatal("failed to listen", "port", port, "error", err)
	}

	s := grpc.NewServer(grpc.UnaryInterceptor(loggingInterceptor))
	pb.RegisterGreeterServer(s, &server{})
	reflection.Register(s)

	healthSrv := health.NewServer()
	healthpb.RegisterHealthServer(s, healthSrv)
	healthSrv.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	healthSrv.SetServingStatus("greeter.Greeter", healthpb.HealthCheckResponse_SERVING)

	slog.Info("gRPC server starting", "port", port, "version", version)
	if err := s.Serve(lis); err != nil {
		logger.Fatal("failed to serve", "error", err)
	}
}
