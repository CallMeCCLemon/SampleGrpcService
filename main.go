package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"time"

	"SampleGrpcProject/internal/db"
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

// version is injected at build time via -ldflags "-X main.version=<semver-sha>".
var version = "dev"

// dbWriter is the subset of db.DB the server needs, allowing a noop in tests.
type dbWriter interface {
	WriteEchoRequest(ctx context.Context, message string) error
}

type server struct {
	pb.UnimplementedGreeterServer
	db dbWriter
}

func (s *server) Echo(ctx context.Context, req *pb.EchoRequest) (*pb.EchoReply, error) {
	if req.Message == "" {
		slog.Warn("Echo called with empty message")
	}
	reply := &pb.EchoReply{Message: req.Message}
	if err := s.db.WriteEchoRequest(ctx, req.Message); err != nil {
		slog.Error("failed to write echo request to db", "error", err)
	}
	return reply, nil
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
				"duration", duration.String(),
			)
		} else {
			slog.Warn("request completed with non-OK status",
				"method", info.FullMethod,
				"code", st.Code().String(),
				"error", err,
				"duration", duration.String(),
			)
		}
		return nil, err
	}

	slog.Info("request completed",
		"method", info.FullMethod,
		"response", fmt.Sprintf("%+v", resp),
		"duration", duration.String(),
	)
	return resp, nil
}

func main() {
	ctx := context.Background()

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		logger.Fatal("DATABASE_URL environment variable is not set")
	}

	slog.Info("connecting to database...")
	database, err := db.New(ctx, dbURL)
	if err != nil {
		logger.Fatal("failed to connect to database", "error", err)
	}
	defer database.Close()
	slog.Info("database connected and schema ready")

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		logger.Fatal("failed to listen", "port", port, "error", err)
	}

	s := grpc.NewServer(grpc.UnaryInterceptor(loggingInterceptor))
	pb.RegisterGreeterServer(s, &server{db: database})
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
