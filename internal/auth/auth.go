// Package auth implements the AuthService gRPC server.
// It handles Google ID token verification, user upsert, and JWT issuance.
// Environment variables:
//   - GOOGLE_JWKS_URL — where to fetch Google's public keys for ID-token verification.
//     Defaults to https://www.googleapis.com/oauth2/v3/certs.
//   - GOOGLE_CLIENT_ID — OAuth 2.0 client ID used to validate the aud claim on
//     Google ID tokens. Must match the client ID configured in Google Cloud Console.
//   - JWT_SECRET — HMAC-SHA256 key used to sign session JWTs issued to clients.
package auth

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Claims holds the validated fields extracted from a session JWT.
type Claims struct {
	UserID  string
	IsAdmin bool
}

// ErrUnauthenticated is returned when a JWT is missing, expired, or has an invalid signature.
var ErrUnauthenticated = errors.New("unauthenticated")

// ErrForbidden is returned when a valid JWT does not carry sufficient privileges.
var ErrForbidden = errors.New("forbidden")

// ValidateJWT parses and verifies a session JWT signed with HMAC-SHA256.
// Returns ErrUnauthenticated for missing, expired, or tampered tokens.
func ValidateJWT(tokenString string, secret []byte) (*Claims, error) {
	if tokenString == "" {
		return nil, ErrUnauthenticated
	}

	tok, err := jwt.ParseWithClaims(tokenString, &jwt.MapClaims{}, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return secret, nil
	}, jwt.WithExpirationRequired())
	if err != nil || !tok.Valid {
		return nil, ErrUnauthenticated
	}

	mc, ok := tok.Claims.(*jwt.MapClaims)
	if !ok {
		return nil, ErrUnauthenticated
	}

	userID, _ := (*mc)["user_id"].(string)
	isAdmin, _ := (*mc)["is_admin"].(bool)

	return &Claims{UserID: userID, IsAdmin: isAdmin}, nil
}

// IssueJWT creates a signed HMAC-SHA256 session JWT for the given user.
// The token lifetime is 24 hours.
func IssueJWT(userID string, isAdmin bool, secret []byte) (string, error) {
	now := time.Now()
	claims := jwt.MapClaims{
		"user_id":  userID,
		"is_admin": isAdmin,
		"iat":      now.Unix(),
		"exp":      now.Add(24 * time.Hour).Unix(),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := tok.SignedString(secret)
	if err != nil {
		return "", fmt.Errorf("sign JWT: %w", err)
	}
	return signed, nil
}

// GoogleClaims holds the verified fields from a Google ID token.
type GoogleClaims struct {
	Sub         string // stable Google subject ID
	Email       string
	DisplayName string // "name" claim
	Picture     string // profile picture URL; empty if not present
}

// VerifyGoogleIDToken verifies a raw Google ID token against the JWKS at jwksURL
// and returns the verified claims.
// The token must be RS256-signed, unexpired, issued by accounts.google.com, and
// addressed to clientID. Pass an empty clientID to skip audience validation (tests only).
// Returns ErrUnauthenticated if any check fails.
func VerifyGoogleIDToken(rawToken string, jwksURL string, clientID string) (*GoogleClaims, error) {
	// Parse the header without verifying so we can look up the right key by kid.
	unverified, _, err := jwt.NewParser().ParseUnverified(rawToken, jwt.MapClaims{})
	if err != nil {
		log.Printf("auth: ParseUnverified failed: %v", err)
		return nil, ErrUnauthenticated
	}

	kid, _ := unverified.Header["kid"].(string)

	pubKey, err := fetchRSAKey(jwksURL, kid)
	if err != nil {
		log.Printf("auth: fetchRSAKey(kid=%q) failed: %v", kid, err)
		return nil, ErrUnauthenticated
	}

	tok, err := jwt.ParseWithClaims(rawToken, &jwt.MapClaims{}, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return pubKey, nil
	}, jwt.WithExpirationRequired())
	if err != nil || !tok.Valid {
		log.Printf("auth: JWT verification failed: %v", err)
		return nil, ErrUnauthenticated
	}

	mc, ok := tok.Claims.(*jwt.MapClaims)
	if !ok {
		log.Printf("auth: claims type assertion failed")
		return nil, ErrUnauthenticated
	}

	// Google issues tokens with both forms of the issuer claim.
	iss, _ := (*mc)["iss"].(string)
	if iss != "accounts.google.com" && iss != "https://accounts.google.com" {
		log.Printf("auth: unexpected issuer: %q", iss)
		return nil, ErrUnauthenticated
	}

	if clientID != "" {
		// aud may be a string or a []interface{} — jwt/v5 normalises both.
		var audMatch bool
		switch v := (*mc)["aud"].(type) {
		case string:
			audMatch = v == clientID
		case []interface{}:
			for _, a := range v {
				if s, ok := a.(string); ok && s == clientID {
					audMatch = true
					break
				}
			}
		}
		if !audMatch {
			aud := (*mc)["aud"]
			log.Printf("auth: audience mismatch: got %v, want %q", aud, clientID)
			return nil, ErrUnauthenticated
		}
	}

	sub, _ := (*mc)["sub"].(string)
	email, _ := (*mc)["email"].(string)
	name, _ := (*mc)["name"].(string)
	picture, _ := (*mc)["picture"].(string)

	return &GoogleClaims{Sub: sub, Email: email, DisplayName: name, Picture: picture}, nil
}

// ─── JWKS helpers ─────────────────────────────────────────────────────────────

type jwksDocument struct {
	Keys []jwkKey `json:"keys"`
}

type jwkKey struct {
	KID string `json:"kid"`
	KTY string `json:"kty"`
	ALG string `json:"alg"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// fetchRSAKey downloads the JWKS from url and returns the RSA public key whose
// kid matches the given kid. Returns an error if the key is not found.
func fetchRSAKey(url, kid string) (*rsa.PublicKey, error) {
	resp, err := http.Get(url) //nolint:noctx // JWKS fetch; timeout via transport default
	if err != nil {
		return nil, fmt.Errorf("fetch JWKS: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read JWKS body: %w", err)
	}

	var doc jwksDocument
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("parse JWKS: %w", err)
	}

	for _, k := range doc.Keys {
		if k.KID != kid {
			continue
		}
		return jwkToRSA(k)
	}

	return nil, fmt.Errorf("kid %q not found in JWKS", kid)
}

// jwkToRSA reconstructs an *rsa.PublicKey from a JWK's base64url-encoded N and E.
func jwkToRSA(k jwkKey) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, fmt.Errorf("decode JWK n: %w", err)
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, fmt.Errorf("decode JWK e: %w", err)
	}

	n := new(big.Int).SetBytes(nBytes)
	e := int(new(big.Int).SetBytes(eBytes).Int64())

	return &rsa.PublicKey{N: n, E: e}, nil
}
