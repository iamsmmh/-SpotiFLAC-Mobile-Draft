// Package auth implements the SpotiFLAC Cloud authentication surface:
// PBKDF2 password hashing, HS256 JWT access tokens, rotating refresh tokens
// with reuse detection, and per-user device registration.
//
// It is a dependency-free reference implementation of the contract in
// docs/API_CONTRACTS.md (§1.3) so the app can be pointed at a self-hosted
// server without any third-party identity provider.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

// ErrInvalidCredentials is returned for unknown users or wrong passwords.
var ErrInvalidCredentials = errors.New("invalid email or password")

// ErrUnauthorized maps to HTTP 401 (missing/expired/invalid token).
var ErrUnauthorized = errors.New("unauthorized")

// ErrEmailTaken is returned when registering an existing address.
var ErrEmailTaken = errors.New("email already registered")

// ErrWeakPassword is returned when a password is too short.
var ErrWeakPassword = errors.New("password must be at least 8 characters")

// ---------------------------------------------------------------------------
// PBKDF2-HMAC-SHA256 password hashing (stdlib-only reimplementation of the
// x/crypto pbkdf2.Key loop).
// ---------------------------------------------------------------------------

// PBKDF2SHA256 derives a key of length keyLen from the password and salt.
func PBKDF2SHA256(password, salt []byte, iterations, keyLen int) []byte {
	prf := hmac.New(sha256.New, password)
	hashLen := prf.Size()
	numBlocks := (keyLen + hashLen - 1) / hashLen

	var buf [4]byte
	dk := make([]byte, 0, numBlocks*hashLen)
	u := make([]byte, hashLen)
	for block := 1; block <= numBlocks; block++ {
		prf.Reset()
		buf[0] = byte(block >> 24)
		buf[1] = byte(block >> 16)
		buf[2] = byte(block >> 8)
		buf[3] = byte(block)
		prf.Write(salt)
		prf.Write(buf[:4])
		dk = prf.Sum(dk)
		t := dk[len(dk)-hashLen:]
		copy(u, t)
		for n := 2; n <= iterations; n++ {
			prf.Reset()
			prf.Write(u)
			u = u[:0]
			u = prf.Sum(u)
			for x := range u {
				t[x] ^= u[x]
			}
		}
	}
	return dk[:keyLen]
}

const (
	passwordIterations = 210_000
	passwordKeyLen     = 32
	saltLen            = 16
)

// HashPassword derives a storable hash in the self-describing format
// "pbkdf2-sha256$<iterations>$<salt-b64>$<hash-b64>".
func HashPassword(password string) (string, error) {
	if len(password) < 8 {
		return "", ErrWeakPassword
	}
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("salt: %w", err)
	}
	dk := PBKDF2SHA256([]byte(password), salt, passwordIterations, passwordKeyLen)
	return fmt.Sprintf(
		"pbkdf2-sha256$%d$%s$%s",
		passwordIterations,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(dk),
	), nil
}

// VerifyPassword reports whether the password matches the stored hash.
// Malformed hashes never match (and never panic).
func VerifyPassword(password, stored string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2-sha256" {
		return false
	}
	var iterations int
	if _, err := fmt.Sscanf(parts[1], "%d", &iterations); err != nil || iterations < 1 {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[3])
	if err != nil || len(want) == 0 {
		return false
	}
	got := PBKDF2SHA256([]byte(password), salt, iterations, len(want))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// ---------------------------------------------------------------------------
// HS256 JSON Web Tokens
// ---------------------------------------------------------------------------

// TokenTTL is the access-token lifetime.
const TokenTTL = time.Hour

// Clock can be replaced in tests.
type Clock func() time.Time

// Claims is the JWT payload. Only registered claims the app needs.
type Claims struct {
	Issuer   string `json:"iss"`
	Subject  string `json:"sub"`
	Audience string `json:"aud"`
	IssuedAt int64  `json:"iat"`
	Expires  int64  `json:"exp"`
}

// TokenIssuer signs and verifies HS256 access tokens.
type TokenIssuer struct {
	secret []byte
	issuer string
	aud    string
	clock  Clock
}

// NewTokenIssuer builds an issuer around a shared secret (>= 32 bytes
// recommended).
func NewTokenIssuer(secret []byte, issuer, audience string, clock Clock) *TokenIssuer {
	return &TokenIssuer{secret: secret, issuer: issuer, aud: audience, clock: clock}
}

func (t *TokenIssuer) now() time.Time {
	if t.clock == nil {
		return time.Now()
	}
	return t.clock()
}

// Issue creates a signed token for userID with the standard TTL.
func (t *TokenIssuer) Issue(userID string) (string, error) {
	return t.IssueWithTTL(userID, TokenTTL)
}

// IssueWithTTL creates a signed token with a custom lifetime.
func (t *TokenIssuer) IssueWithTTL(userID string, ttl time.Duration) (string, error) {
	now := t.now().UTC()
	claims := Claims{
		Issuer:   t.issuer,
		Subject:  userID,
		Audience: t.aud,
		IssuedAt: now.Unix(),
		Expires:  now.Add(ttl).Unix(),
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	payloadJSON, err := json.Marshal(claims)
	if err != nil {
		return "", fmt.Errorf("claims: %w", err)
	}
	payload := base64.RawURLEncoding.EncodeToString(payloadJSON)
	signingInput := header + "." + payload
	return signingInput + "." + t.sign(signingInput), nil
}

func (t *TokenIssuer) sign(signingInput string) string {
	mac := hmac.New(sha256.New, t.secret)
	mac.Write([]byte(signingInput))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// Verify validates signature, algorithm, and expiry (30 s leeway) and
// returns the subject (user id).
func (t *TokenIssuer) Verify(token string) (string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", ErrUnauthorized
	}
	expected := t.sign(parts[0] + "." + parts[1])
	if subtle.ConstantTimeCompare([]byte(expected), []byte(parts[2])) != 1 {
		return "", ErrUnauthorized
	}
	payloadJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", ErrUnauthorized
	}
	var claims Claims
	if err := json.Unmarshal(payloadJSON, &claims); err != nil {
		return "", ErrUnauthorized
	}
	if claims.Issuer != t.issuer || claims.Audience != t.aud {
		return "", ErrUnauthorized
	}
	now := t.now().Unix()
	if claims.Expires < now-30 || claims.IssuedAt > now+30 {
		return "", ErrUnauthorized
	}
	if claims.Subject == "" {
		return "", ErrUnauthorized
	}
	return claims.Subject, nil
}
