package db

import (
	"context"
	"fmt"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// EchoRequest represents a row in the echo_requests table.
type EchoRequest struct {
	ID        uint      `gorm:"primarykey;autoIncrement"`
	Message   string    `gorm:"not null"`
	CreatedAt time.Time `gorm:"not null;autoCreateTime"`
}

// DB wraps a GORM database connection.
type DB struct {
	orm *gorm.DB
}

// New opens a connection to the database and runs AutoMigrate.
func New(ctx context.Context, connStr string) (*DB, error) {
	orm, err := gorm.Open(postgres.Open(connStr), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	if err := orm.WithContext(ctx).AutoMigrate(&EchoRequest{}); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}

	return &DB{orm: orm}, nil
}

// Close releases the underlying database connection.
func (d *DB) Close() {
	if sqlDB, err := d.orm.DB(); err == nil {
		sqlDB.Close()
	}
}

// WriteEchoRequest persists an Echo request message.
func (d *DB) WriteEchoRequest(ctx context.Context, message string) error {
	return d.orm.WithContext(ctx).Create(&EchoRequest{Message: message}).Error
}
