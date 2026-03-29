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

func TestIntegration_WriteEchoRequest(t *testing.T) {
	db := startPostgres(t)
	ctx := context.Background()

	if err := db.WriteEchoRequest(ctx, "hello world"); err != nil {
		t.Fatalf("WriteEchoRequest error: %v", err)
	}

	var rows []EchoRequest
	if err := db.orm.WithContext(ctx).Find(&rows).Error; err != nil {
		t.Fatalf("failed to query echo_requests: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0].Message != "hello world" {
		t.Errorf("unexpected row: %+v", rows[0])
	}
}

func TestIntegration_MultipleWrites(t *testing.T) {
	db := startPostgres(t)
	ctx := context.Background()

	messages := []string{"foo", "bar", "baz"}
	for _, msg := range messages {
		if err := db.WriteEchoRequest(ctx, msg); err != nil {
			t.Fatalf("WriteEchoRequest(%q) error: %v", msg, err)
		}
	}

	var rows []EchoRequest
	db.orm.WithContext(ctx).Find(&rows)
	if len(rows) != len(messages) {
		t.Errorf("echo_requests: expected %d rows, got %d", len(messages), len(rows))
	}
}

func TestIntegration_AutoMigrate(t *testing.T) {
	db := startPostgres(t)
	ctx := context.Background()

	// Verify the table exists by querying it without error.
	if err := db.orm.WithContext(ctx).Find(&[]EchoRequest{}).Error; err != nil {
		t.Errorf("echo_requests table missing: %v", err)
	}
}
