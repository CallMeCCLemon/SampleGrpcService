package db

import (
	"context"
	"errors"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// newMockDB creates a DB backed by sqlmock for fast unit tests.
func newMockDB(t *testing.T) (*DB, sqlmock.Sqlmock) {
	t.Helper()

	sqlDB, mock, err := sqlmock.New()
	if err != nil {
		t.Fatalf("failed to create sqlmock: %v", err)
	}
	t.Cleanup(func() { sqlDB.Close() })

	orm, err := gorm.Open(
		postgres.New(postgres.Config{Conn: sqlDB, PreferSimpleProtocol: true}),
		&gorm.Config{Logger: logger.Default.LogMode(logger.Silent)},
	)
	if err != nil {
		t.Fatalf("failed to open gorm: %v", err)
	}

	return &DB{orm: orm}, mock
}

func TestWriteHelloRequest_Success(t *testing.T) {
	db, mock := newMockDB(t)

	mock.ExpectBegin()
	mock.ExpectQuery(`INSERT INTO "hello_requests"`).
		WithArgs("World", "Hello, World!", sqlmock.AnyArg()).
		WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(1))
	mock.ExpectCommit()

	if err := db.WriteHelloRequest(context.Background(), "World", "Hello, World!"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("unmet expectations: %v", err)
	}
}

func TestWriteHelloRequest_DBError(t *testing.T) {
	db, mock := newMockDB(t)
	dbErr := errors.New("connection lost")

	mock.ExpectBegin()
	mock.ExpectQuery(`INSERT INTO "hello_requests"`).
		WithArgs("World", "Hello, World!", sqlmock.AnyArg()).
		WillReturnError(dbErr)
	mock.ExpectRollback()

	if err := db.WriteHelloRequest(context.Background(), "World", "Hello, World!"); err == nil {
		t.Fatal("expected error, got nil")
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("unmet expectations: %v", err)
	}
}

func TestWriteGoodbyeRequest_Success(t *testing.T) {
	db, mock := newMockDB(t)

	mock.ExpectBegin()
	mock.ExpectQuery(`INSERT INTO "goodbye_requests"`).
		WithArgs("World", "Goodbye, World!", sqlmock.AnyArg()).
		WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(1))
	mock.ExpectCommit()

	if err := db.WriteGoodbyeRequest(context.Background(), "World", "Goodbye, World!"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("unmet expectations: %v", err)
	}
}

func TestWriteGoodbyeRequest_DBError(t *testing.T) {
	db, mock := newMockDB(t)
	dbErr := errors.New("connection lost")

	mock.ExpectBegin()
	mock.ExpectQuery(`INSERT INTO "goodbye_requests"`).
		WithArgs("World", "Goodbye, World!", sqlmock.AnyArg()).
		WillReturnError(dbErr)
	mock.ExpectRollback()

	if err := db.WriteGoodbyeRequest(context.Background(), "World", "Goodbye, World!"); err == nil {
		t.Fatal("expected error, got nil")
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("unmet expectations: %v", err)
	}
}
