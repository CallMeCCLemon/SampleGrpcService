//go:build integration

package db

import (
	"context"
	"testing"
	"time"

	"github.com/testcontainers/testcontainers-go"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"
)

func startPostgres(t *testing.T) *DB {
	t.Helper()
	ctx := context.Background()

	ctr, err := tcpostgres.Run(ctx,
		"postgres:16-alpine",
		tcpostgres.WithDatabase("greeter"),
		tcpostgres.WithUsername("greeter"),
		tcpostgres.WithPassword("testpassword"),
		testcontainers.WithWaitStrategy(
			wait.ForListeningPort("5432/tcp").WithStartupTimeout(60*time.Second),
		),
	)
	if err != nil {
		t.Fatalf("failed to start postgres container: %v", err)
	}
	t.Cleanup(func() { ctr.Terminate(ctx) })

	connStr, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("failed to get connection string: %v", err)
	}

	db, err := New(ctx, connStr)
	if err != nil {
		t.Fatalf("failed to connect to db: %v", err)
	}
	t.Cleanup(db.Close)

	return db
}

func TestIntegration_WriteHelloRequest(t *testing.T) {
	db := startPostgres(t)
	ctx := context.Background()

	if err := db.WriteHelloRequest(ctx, "World", "Hello, World!"); err != nil {
		t.Fatalf("WriteHelloRequest error: %v", err)
	}

	var rows []HelloRequest
	if err := db.orm.WithContext(ctx).Find(&rows).Error; err != nil {
		t.Fatalf("failed to query hello_requests: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0].Name != "World" || rows[0].Message != "Hello, World!" {
		t.Errorf("unexpected row: %+v", rows[0])
	}
}

func TestIntegration_WriteGoodbyeRequest(t *testing.T) {
	db := startPostgres(t)
	ctx := context.Background()

	if err := db.WriteGoodbyeRequest(ctx, "World", "Goodbye, World!"); err != nil {
		t.Fatalf("WriteGoodbyeRequest error: %v", err)
	}

	var rows []GoodbyeRequest
	if err := db.orm.WithContext(ctx).Find(&rows).Error; err != nil {
		t.Fatalf("failed to query goodbye_requests: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0].Name != "World" || rows[0].Message != "Goodbye, World!" {
		t.Errorf("unexpected row: %+v", rows[0])
	}
}

func TestIntegration_MultipleWrites(t *testing.T) {
	db := startPostgres(t)
	ctx := context.Background()

	names := []string{"Alice", "Bob", "Charlie"}
	for _, name := range names {
		if err := db.WriteHelloRequest(ctx, name, "Hello, "+name+"!"); err != nil {
			t.Fatalf("WriteHelloRequest(%q) error: %v", name, err)
		}
		if err := db.WriteGoodbyeRequest(ctx, name, "Goodbye, "+name+"!"); err != nil {
			t.Fatalf("WriteGoodbyeRequest(%q) error: %v", name, err)
		}
	}

	var helloRows []HelloRequest
	db.orm.WithContext(ctx).Find(&helloRows)
	if len(helloRows) != len(names) {
		t.Errorf("hello_requests: expected %d rows, got %d", len(names), len(helloRows))
	}

	var goodbyeRows []GoodbyeRequest
	db.orm.WithContext(ctx).Find(&goodbyeRows)
	if len(goodbyeRows) != len(names) {
		t.Errorf("goodbye_requests: expected %d rows, got %d", len(names), len(goodbyeRows))
	}
}

func TestIntegration_AutoMigrate(t *testing.T) {
	db := startPostgres(t)
	ctx := context.Background()

	// Verify both tables exist by querying them without error.
	if err := db.orm.WithContext(ctx).Find(&[]HelloRequest{}).Error; err != nil {
		t.Errorf("hello_requests table missing: %v", err)
	}
	if err := db.orm.WithContext(ctx).Find(&[]GoodbyeRequest{}).Error; err != nil {
		t.Errorf("goodbye_requests table missing: %v", err)
	}
}
