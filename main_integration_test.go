package main

import (
	"context"
	"net"
	"testing"

	pb "SampleGrpcProject/pb"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// noopDB satisfies dbWriter for tests, discarding all writes.
type noopDB struct{}

func (n *noopDB) WriteHelloRequest(_ context.Context, _, _ string) error   { return nil }
func (n *noopDB) WriteGoodbyeRequest(_ context.Context, _, _ string) error { return nil }

func startTestServer(t *testing.T) string {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}

	s := grpc.NewServer()
	pb.RegisterGreeterServer(s, &server{db: &noopDB{}})

	go func() {
		if err := s.Serve(lis); err != nil {
			// server stopped, expected on cleanup
		}
	}()
	t.Cleanup(s.Stop)

	return lis.Addr().String()
}

func newTestClient(t *testing.T, addr string) pb.GreeterClient {
	t.Helper()
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("failed to connect: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	return pb.NewGreeterClient(conn)
}

func TestSayHello(t *testing.T) {
	client := newTestClient(t, startTestServer(t))

	tests := []struct {
		name    string
		input   string
		wantMsg string
	}{
		{"typical name", "World", "Hello, World!"},
		{"empty name", "", "Hello, !"},
		{"name with spaces", "John Doe", "Hello, John Doe!"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := client.SayHello(context.Background(), &pb.HelloRequest{Name: tt.input})
			if err != nil {
				t.Fatalf("SayHello error: %v", err)
			}
			if resp.Message != tt.wantMsg {
				t.Errorf("got %q, want %q", resp.Message, tt.wantMsg)
			}
		})
	}
}

func TestSayGoodbye(t *testing.T) {
	client := newTestClient(t, startTestServer(t))

	tests := []struct {
		name    string
		input   string
		wantMsg string
	}{
		{"typical name", "World", "Goodbye, World!"},
		{"empty name", "", "Goodbye, !"},
		{"name with spaces", "John Doe", "Goodbye, John Doe!"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := client.SayGoodbye(context.Background(), &pb.GoodbyeRequest{Name: tt.input})
			if err != nil {
				t.Fatalf("SayGoodbye error: %v", err)
			}
			if resp.Message != tt.wantMsg {
				t.Errorf("got %q, want %q", resp.Message, tt.wantMsg)
			}
		})
	}
}
