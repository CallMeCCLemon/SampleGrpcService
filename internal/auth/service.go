package auth

import (
	"context"
	"errors"
	"log"
	"os"
	"regexp"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"SampleGrpcProject/internal/db"
	"SampleGrpcProject/pb"
)

// usernameRE validates player-chosen usernames: 3–30 chars, alphanumeric + underscore.
var usernameRE = regexp.MustCompile(`^[a-zA-Z0-9_]{3,30}$`)

const defaultJWKSURL = "https://www.googleapis.com/oauth2/v3/certs"

// Server implements pb.AuthServiceServer.
type Server struct {
	pb.UnimplementedAuthServiceServer
	db             *db.DB
	jwtSecret      []byte
	jwksURL        string
	googleClientID string
}

// NewServer constructs an AuthService handler reading configuration from env vars:
//   - GOOGLE_JWKS_URL   — defaults to Google's production JWKS endpoint
//   - GOOGLE_CLIENT_ID  — required; validates the aud claim on Google ID tokens
//   - JWT_SECRET        — HMAC-SHA256 key for session tokens
func NewServer(database *db.DB) *Server {
	jwksURL := os.Getenv("GOOGLE_JWKS_URL")
	if jwksURL == "" {
		jwksURL = defaultJWKSURL
	}
	return &Server{
		db:             database,
		jwtSecret:      []byte(os.Getenv("JWT_SECRET")),
		jwksURL:        jwksURL,
		googleClientID: os.Getenv("GOOGLE_CLIENT_ID"),
	}
}

// userToProto converts a db.User to its protobuf representation.
func userToProto(u *db.User) *pb.User {
	proto := &pb.User{
		Id:          u.ID,
		Email:       u.Email,
		DisplayName: u.DisplayName,
		IsAdmin:     u.IsAdmin,
	}
	if u.Username != nil {
		proto.Username = *u.Username
	}
	if u.PictureURL != nil {
		proto.PictureUrl = *u.PictureURL
	}
	return proto
}

// LoginWithGoogle verifies a Google ID token, upserts the user record, and
// returns a session JWT.
func (s *Server) LoginWithGoogle(ctx context.Context, req *pb.GoogleLoginRequest) (*pb.SessionResponse, error) {
	if req.IdToken == "" {
		return nil, status.Error(codes.InvalidArgument, "id_token is required")
	}

	gClaims, err := VerifyGoogleIDToken(req.IdToken, s.jwksURL, s.googleClientID)
	if err != nil {
		log.Printf("auth: VerifyGoogleIDToken failed: %v", err)
		return nil, status.Error(codes.Unauthenticated, "invalid Google ID token")
	}

	user, err := s.db.UpsertUser(ctx, gClaims.Sub, gClaims.Email, gClaims.DisplayName, gClaims.Picture, GenerateUsername)
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to upsert user")
	}

	sessionJWT, err := IssueJWT(user.ID, user.IsAdmin, s.jwtSecret)
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to issue session token")
	}

	return &pb.SessionResponse{
		Jwt:  sessionJWT,
		User: userToProto(user),
	}, nil
}

// UpdateProfile updates the authenticated caller's username.
// Send an empty string to clear the username.
func (s *Server) UpdateProfile(ctx context.Context, req *pb.UpdateProfileRequest) (*pb.User, error) {
	claims, ok := ClaimsFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing auth context")
	}

	if req.Username != "" && !usernameRE.MatchString(req.Username) {
		return nil, status.Error(codes.InvalidArgument,
			"username must be 3–30 characters and contain only letters, numbers, and underscores")
	}

	user, err := s.db.UpdateUsername(ctx, claims.UserID, req.Username)
	if err != nil {
		if errors.Is(err, db.ErrUsernameTaken) {
			return nil, status.Error(codes.AlreadyExists, "username is already taken")
		}
		return nil, status.Error(codes.Internal, "failed to update profile")
	}

	return userToProto(user), nil
}

// GetCurrentUser returns the profile of the authenticated caller.
func (s *Server) GetCurrentUser(ctx context.Context, _ *pb.GetCurrentUserRequest) (*pb.User, error) {
	claims, ok := ClaimsFromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing auth context")
	}

	user, err := s.db.GetUserByID(ctx, claims.UserID)
	if err != nil {
		return nil, status.Error(codes.NotFound, "user not found")
	}

	return userToProto(user), nil
}

// ListUsers returns all user accounts (admin only — enforced by interceptor).
func (s *Server) ListUsers(ctx context.Context, _ *pb.ListUsersRequest) (*pb.ListUsersResponse, error) {
	users, err := s.db.ListUsers(ctx)
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to list users")
	}
	resp := &pb.ListUsersResponse{}
	for _, u := range users {
		resp.Users = append(resp.Users, userToProto(u))
	}
	return resp, nil
}
