package db

import (
	"context"
	"fmt"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// HelloRequest represents a row in the hello_requests table.
type HelloRequest struct {
	ID        uint      `gorm:"primarykey;autoIncrement"`
	Name      string    `gorm:"not null"`
	Message   string    `gorm:"not null"`
	CreatedAt time.Time `gorm:"not null;autoCreateTime"`
}

// GoodbyeRequest represents a row in the goodbye_requests table.
type GoodbyeRequest struct {
	ID        uint      `gorm:"primarykey;autoIncrement"`
	Name      string    `gorm:"not null"`
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

	if err := orm.WithContext(ctx).AutoMigrate(&HelloRequest{}, &GoodbyeRequest{}); err != nil {
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

// WriteHelloRequest persists a SayHello request and its response message.
func (d *DB) WriteHelloRequest(ctx context.Context, name, message string) error {
	return d.orm.WithContext(ctx).Create(&HelloRequest{Name: name, Message: message}).Error
}

// WriteGoodbyeRequest persists a SayGoodbye request and its response message.
func (d *DB) WriteGoodbyeRequest(ctx context.Context, name, message string) error {
	return d.orm.WithContext(ctx).Create(&GoodbyeRequest{Name: name, Message: message}).Error
}
