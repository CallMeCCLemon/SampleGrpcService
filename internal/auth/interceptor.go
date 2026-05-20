package auth

import (
	"context"
	"os"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// claimsKey is the context key used to propagate verified Claims between the
// interceptor and service handlers. Unexported to prevent external collision.
type contextKey struct{}

var claimsKey = contextKey{}

// ClaimsFromContext retrieves the verified Claims injected by the interceptor.
// Returns (nil, false) if the context has no claims (e.g. unauthenticated RPCs).
func ClaimsFromContext(ctx context.Context) (*Claims, bool) {
	c, ok := ctx.Value(claimsKey).(*Claims)
	return c, ok && c != nil
}

// WithClaims returns a context with the provided Claims attached under the
// same key the interceptor uses. Intended for tests that need to invoke
// service handlers without standing up a full gRPC pipeline.
func WithClaims(ctx context.Context, claims *Claims) context.Context {
	return context.WithValue(ctx, claimsKey, claims)
}

// publicRPCs is the set of fully-qualified method names that do not require a
// session JWT. All other RPCs are gated by the interceptor.
var publicRPCs = map[string]bool{
	"/greeter.AuthService/LoginWithGoogle": true,
	// Echo is the demo RPC and stays anonymous so curl-from-the-internet works
	// without sign-in. Move into the authed allowlist (i.e. delete this line)
	// to require a session JWT for Echo.
	"/greeter.Greeter/Echo": true,
	// gRPC health checks used by k8s liveness/readiness probes must be unauthenticated.
	"/grpc.health.v1.Health/Check": true,
	"/grpc.health.v1.Health/Watch": true,
	// Reflection is enabled for grpcurl convenience; keep it open.
	"/grpc.reflection.v1.ServerReflection/ServerReflectionInfo":      true,
	"/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo": true,
}

// adminRPCs is the set of fully-qualified method names that require IsAdmin=true.
var adminRPCs = map[string]bool{
	"/greeter.AuthService/ListUsers": true,
}

// UnaryAuthInterceptor is a gRPC server interceptor that validates the session
// JWT on every non-public RPC and injects the resulting Claims into the context.
// Returns codes.Unauthenticated for missing/invalid JWTs.
// Returns codes.PermissionDenied for non-admin callers on admin-only RPCs.
func UnaryAuthInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
	if publicRPCs[info.FullMethod] {
		return handler(ctx, req)
	}

	claims, err := extractClaims(ctx)
	if err != nil {
		return nil, err
	}

	if adminRPCs[info.FullMethod] && !claims.IsAdmin {
		return nil, status.Error(codes.PermissionDenied, "admin access required")
	}

	return handler(context.WithValue(ctx, claimsKey, claims), req)
}

// extractClaims reads the Bearer token from the incoming gRPC metadata and
// validates it. Returns ErrUnauthenticated wrapped as a gRPC status error.
func extractClaims(ctx context.Context) (*Claims, error) {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing metadata")
	}

	vals := md.Get("authorization")
	if len(vals) == 0 {
		return nil, status.Error(codes.Unauthenticated, "missing authorization header")
	}

	token := strings.TrimPrefix(vals[0], "Bearer ")
	if token == vals[0] { // prefix not present
		return nil, status.Error(codes.Unauthenticated, "authorization must be Bearer <token>")
	}

	secret := []byte(os.Getenv("JWT_SECRET"))
	claims, err := ValidateJWT(token, secret)
	if err != nil {
		return nil, status.Error(codes.Unauthenticated, "invalid or expired token")
	}

	return claims, nil
}
