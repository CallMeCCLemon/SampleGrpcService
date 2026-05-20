package auth

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func TestIssueAndValidateJWT_RoundTrip(t *testing.T) {
	secret := []byte("test-secret-32-bytes-of-padding!!")

	token, err := IssueJWT("user-123", true, secret)
	if err != nil {
		t.Fatalf("IssueJWT: %v", err)
	}

	claims, err := ValidateJWT(token, secret)
	if err != nil {
		t.Fatalf("ValidateJWT: %v", err)
	}
	if claims.UserID != "user-123" {
		t.Errorf("UserID = %q, want user-123", claims.UserID)
	}
	if !claims.IsAdmin {
		t.Errorf("IsAdmin = false, want true")
	}
}

func TestValidateJWT_WrongSecret(t *testing.T) {
	token, _ := IssueJWT("u", false, []byte("right-secret-32-bytes-padding!!!"))
	if _, err := ValidateJWT(token, []byte("wrong-secret-32-bytes-padding!!!")); !errors.Is(err, ErrUnauthenticated) {
		t.Errorf("expected ErrUnauthenticated, got %v", err)
	}
}

func TestValidateJWT_Expired(t *testing.T) {
	secret := []byte("test-secret-32-bytes-of-padding!!")
	// Manually craft an expired token; IssueJWT always issues a 24h lifetime.
	claims := jwt.MapClaims{
		"user_id":  "u",
		"is_admin": false,
		"iat":      time.Now().Add(-2 * time.Hour).Unix(),
		"exp":      time.Now().Add(-1 * time.Hour).Unix(),
	}
	expired, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(secret)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if _, err := ValidateJWT(expired, secret); !errors.Is(err, ErrUnauthenticated) {
		t.Errorf("expected ErrUnauthenticated for expired token, got %v", err)
	}
}

func TestValidateJWT_EmptyToken(t *testing.T) {
	if _, err := ValidateJWT("", []byte("secret")); !errors.Is(err, ErrUnauthenticated) {
		t.Errorf("expected ErrUnauthenticated for empty token, got %v", err)
	}
}

// ── Interceptor matrix ────────────────────────────────────────────────────────

func mkInfo(method string) *grpc.UnaryServerInfo {
	return &grpc.UnaryServerInfo{FullMethod: method}
}

func okHandler(ctx context.Context, _ any) (any, error) { return "ok", nil }

func TestInterceptor_PublicRPC_NoToken(t *testing.T) {
	resp, err := UnaryAuthInterceptor(context.Background(), nil,
		mkInfo("/greeter.AuthService/LoginWithGoogle"), okHandler)
	if err != nil || resp != "ok" {
		t.Errorf("public RPC should pass through; got resp=%v err=%v", resp, err)
	}
}

func TestInterceptor_PrivateRPC_NoMetadata(t *testing.T) {
	_, err := UnaryAuthInterceptor(context.Background(), nil,
		mkInfo("/greeter.AuthService/UpdateProfile"), okHandler)
	if status.Code(err) != codes.Unauthenticated {
		t.Errorf("expected Unauthenticated, got %v", err)
	}
}

func TestInterceptor_PrivateRPC_BadToken(t *testing.T) {
	t.Setenv("JWT_SECRET", "test-secret-32-bytes-of-padding!!")
	md := metadata.New(map[string]string{"authorization": "Bearer not-a-jwt"})
	ctx := metadata.NewIncomingContext(context.Background(), md)
	_, err := UnaryAuthInterceptor(ctx, nil, mkInfo("/greeter.AuthService/UpdateProfile"), okHandler)
	if status.Code(err) != codes.Unauthenticated {
		t.Errorf("expected Unauthenticated, got %v", err)
	}
}

func TestInterceptor_PrivateRPC_ValidToken_NonAdmin(t *testing.T) {
	secret := []byte("test-secret-32-bytes-of-padding!!")
	t.Setenv("JWT_SECRET", string(secret))
	token, _ := IssueJWT("user-x", false, secret)
	md := metadata.New(map[string]string{"authorization": "Bearer " + token})
	ctx := metadata.NewIncomingContext(context.Background(), md)

	captured := ""
	resp, err := UnaryAuthInterceptor(ctx, nil, mkInfo("/greeter.AuthService/UpdateProfile"),
		func(ctx context.Context, _ any) (any, error) {
			if c, ok := ClaimsFromContext(ctx); ok {
				captured = c.UserID
			}
			return "ok", nil
		})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp != "ok" || captured != "user-x" {
		t.Errorf("resp=%v captured=%q; want resp=ok captured=user-x", resp, captured)
	}
}

func TestInterceptor_AdminRPC_NonAdminDenied(t *testing.T) {
	secret := []byte("test-secret-32-bytes-of-padding!!")
	t.Setenv("JWT_SECRET", string(secret))
	token, _ := IssueJWT("user-x", false, secret)
	md := metadata.New(map[string]string{"authorization": "Bearer " + token})
	ctx := metadata.NewIncomingContext(context.Background(), md)

	_, err := UnaryAuthInterceptor(ctx, nil, mkInfo("/greeter.AuthService/ListUsers"), okHandler)
	if status.Code(err) != codes.PermissionDenied {
		t.Errorf("expected PermissionDenied for non-admin on ListUsers, got %v", err)
	}
}

func TestInterceptor_AdminRPC_AdminAllowed(t *testing.T) {
	secret := []byte("test-secret-32-bytes-of-padding!!")
	t.Setenv("JWT_SECRET", string(secret))
	token, _ := IssueJWT("admin-x", true, secret)
	md := metadata.New(map[string]string{"authorization": "Bearer " + token})
	ctx := metadata.NewIncomingContext(context.Background(), md)

	resp, err := UnaryAuthInterceptor(ctx, nil, mkInfo("/greeter.AuthService/ListUsers"), okHandler)
	if err != nil || resp != "ok" {
		t.Errorf("admin on ListUsers should pass; got resp=%v err=%v", resp, err)
	}
}

func TestInterceptor_BareTokenWithoutBearerPrefixRejected(t *testing.T) {
	secret := []byte("test-secret-32-bytes-of-padding!!")
	t.Setenv("JWT_SECRET", string(secret))
	token, _ := IssueJWT("u", false, secret)
	md := metadata.New(map[string]string{"authorization": token}) // no "Bearer "
	ctx := metadata.NewIncomingContext(context.Background(), md)

	_, err := UnaryAuthInterceptor(ctx, nil, mkInfo("/greeter.AuthService/UpdateProfile"), okHandler)
	if status.Code(err) != codes.Unauthenticated {
		t.Errorf("expected Unauthenticated for missing Bearer prefix, got %v", err)
	}
}
