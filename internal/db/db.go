package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// DB wraps a pgx connection pool and exposes methods for each gRPC API.
type DB struct {
	pool *pgxpool.Pool
}

// New connects to the database at connStr and runs schema migrations.
func New(ctx context.Context, connStr string) (*DB, error) {
	pool, err := pgxpool.New(ctx, connStr)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping db: %w", err)
	}
	d := &DB{pool: pool}
	if err := d.migrate(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return d, nil
}

// Close releases all connections in the pool.
func (d *DB) Close() {
	d.pool.Close()
}

// migrate creates the request tables if they do not already exist.
func (d *DB) migrate(ctx context.Context) error {
	_, err := d.pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS hello_requests (
			id         BIGSERIAL    PRIMARY KEY,
			name       TEXT         NOT NULL,
			message    TEXT         NOT NULL,
			created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
		)
	`)
	if err != nil {
		return fmt.Errorf("create hello_requests: %w", err)
	}

	_, err = d.pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS goodbye_requests (
			id         BIGSERIAL    PRIMARY KEY,
			name       TEXT         NOT NULL,
			message    TEXT         NOT NULL,
			created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
		)
	`)
	if err != nil {
		return fmt.Errorf("create goodbye_requests: %w", err)
	}

	return nil
}

// WriteHelloRequest persists a SayHello request and its response message.
func (d *DB) WriteHelloRequest(ctx context.Context, name, message string) error {
	_, err := d.pool.Exec(ctx,
		`INSERT INTO hello_requests (name, message) VALUES ($1, $2)`,
		name, message,
	)
	return err
}

// WriteGoodbyeRequest persists a SayGoodbye request and its response message.
func (d *DB) WriteGoodbyeRequest(ctx context.Context, name, message string) error {
	_, err := d.pool.Exec(ctx,
		`INSERT INTO goodbye_requests (name, message) VALUES ($1, $2)`,
		name, message,
	)
	return err
}
