package db

import (
	"context"
	"fmt"
	"strings"
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

// User represents a row in the users table. The Google subject claim
// (GoogleSub) is the unique key used for upsert on sign-in.
type User struct {
	ID          string `gorm:"primaryKey;type:uuid;default:gen_random_uuid()"`
	GoogleSub   string `gorm:"uniqueIndex;not null"`
	Email       string `gorm:"not null"`
	DisplayName string `gorm:"not null"`
	// PictureURL is the Google profile picture URL, refreshed on every sign-in.
	// NULL for users whose Google account has no profile picture.
	PictureURL *string `gorm:"type:text"`
	// Username is an optional player-chosen handle (3–30 alphanumeric/underscore chars).
	// NULL means not yet set; the unique index allows multiple NULLs in Postgres.
	Username  *string `gorm:"uniqueIndex;type:varchar(30)"`
	IsAdmin   bool    `gorm:"not null;default:false"`
	CreatedAt time.Time
	UpdatedAt time.Time
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

	if err := orm.WithContext(ctx).AutoMigrate(&EchoRequest{}, &User{}); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}

	return &DB{orm: orm}, nil
}

// Close releases the underlying database connection.
func (d *DB) Close() {
	if sqlDB, err := d.orm.DB(); err == nil {
		_ = sqlDB.Close()
	}
}

// WriteEchoRequest persists an Echo request message.
func (d *DB) WriteEchoRequest(ctx context.Context, message string) error {
	return d.orm.WithContext(ctx).Create(&EchoRequest{Message: message}).Error
}

// ── User methods ──────────────────────────────────────────────────────────────

// ErrUsernameTaken is returned when a requested username is already in use.
var ErrUsernameTaken = fmt.Errorf("username already taken")

// UpsertUser creates or refreshes a user record keyed by Google subject.
// On creation, calls generateUsername to assign an initial handle (retrying
// up to 10 times on collision); on existing rows, updates the cached profile
// fields. Returns the full, post-upsert user record.
func (d *DB) UpsertUser(ctx context.Context, googleSub, email, displayName, pictureURL string, generateUsername func() string) (*User, error) {
	var pic *string
	if pictureURL != "" {
		pic = &pictureURL
	}

	u := User{
		GoogleSub:   googleSub,
		Email:       email,
		DisplayName: displayName,
		PictureURL:  pic,
	}

	result := d.orm.WithContext(ctx).
		Where(User{GoogleSub: googleSub}).
		Assign(User{Email: email, DisplayName: displayName, PictureURL: pic}).
		FirstOrCreate(&u)
	if result.Error != nil {
		return nil, fmt.Errorf("upsert user: %w", result.Error)
	}

	if u.Username == nil {
		for range 10 {
			candidate := generateUsername()
			updated, err := d.UpdateUsername(ctx, u.ID, candidate)
			if err == nil {
				return updated, nil
			}
		}
		// Give up gracefully — the user can pick one via UpdateProfile later.
		return d.GetUserByID(ctx, u.ID)
	}

	return &u, nil
}

// GetUserByID returns the user with the given UUID, or an error if not found.
func (d *DB) GetUserByID(ctx context.Context, id string) (*User, error) {
	var u User
	if err := d.orm.WithContext(ctx).First(&u, "id = ?", id).Error; err != nil {
		return nil, fmt.Errorf("get user %s: %w", id, err)
	}
	return &u, nil
}

// ListUsers returns all user accounts ordered by creation time (oldest first).
func (d *DB) ListUsers(ctx context.Context) ([]*User, error) {
	var users []*User
	if err := d.orm.WithContext(ctx).Order("created_at asc").Find(&users).Error; err != nil {
		return nil, fmt.Errorf("list users: %w", err)
	}
	return users, nil
}

// UpdateUsername sets the username for the given user ID.
// Pass an empty string to clear the username (sets it to NULL).
// Returns ErrUsernameTaken if the username is already claimed by another user.
func (d *DB) UpdateUsername(ctx context.Context, userID, username string) (*User, error) {
	var newUsername *string
	if username != "" {
		newUsername = &username
	}

	result := d.orm.WithContext(ctx).
		Model(&User{}).
		Where("id = ?", userID).
		Update("username", newUsername)
	if result.Error != nil {
		if isUniqueViolation(result.Error) {
			return nil, ErrUsernameTaken
		}
		return nil, fmt.Errorf("update username: %w", result.Error)
	}

	return d.GetUserByID(ctx, userID)
}

// isUniqueViolation matches Postgres unique-constraint errors (SQLSTATE 23505)
// by scanning the error message, which is portable across GORM/pgx versions.
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "23505") || strings.Contains(msg, "unique")
}
