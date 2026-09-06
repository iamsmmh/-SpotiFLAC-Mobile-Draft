package auth

import (
	"context"
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

func TestPBKDF2KnownVector(t *testing.T) {
	// RFC 6070-style structure (SHA-1 there, SHA-256 here): the vector below
	// is cross-checked against Python's hashlib.pbkdf2_hmac.
	got := PBKDF2SHA256([]byte("password"), []byte("salt"), 1, 32)
	want := "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
	if hex.EncodeToString(got) != want {
		t.Fatalf("PBKDF2 vector mismatch: got %s", hex.EncodeToString(got))
	}
}

func TestHashAndVerifyPassword(t *testing.T) {
	hash, err := HashPassword("correct horse battery")
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	if !strings.HasPrefix(hash, "pbkdf2-sha256$210000$") {
		t.Fatalf("unexpected hash format: %q", hash[:24])
	}
	if !VerifyPassword("correct horse battery", hash) {
		t.Fatal("correct password rejected")
	}
	if VerifyPassword("wrong password", hash) {
		t.Fatal("wrong password accepted")
	}
	if VerifyPassword("anything", "garbage") {
		t.Fatal("malformed hash accepted")
	}
	if _, err := HashPassword("short"); err != ErrWeakPassword {
		t.Fatalf("short password: got %v, want ErrWeakPassword", err)
	}
}

func TestTokenIssueVerifyRoundTrip(t *testing.T) {
	issuer := NewTokenIssuer([]byte("test-secret-0123456789abcdef0123"), "spotiflac-cloud", "spotiflac-mobile", nil)
	token, err := issuer.Issue("usr_abc")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	subject, err := issuer.Verify(token)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if subject != "usr_abc" {
		t.Fatalf("subject = %q, want usr_abc", subject)
	}
}

func TestTokenRejectsTamperingAndForeignIssuers(t *testing.T) {
	issuer := NewTokenIssuer([]byte("test-secret-0123456789abcdef0123"), "spotiflac-cloud", "spotiflac-mobile", nil)
	other := NewTokenIssuer([]byte("another-secret-0123456789abcdef"), "spotiflac-cloud", "spotiflac-mobile", nil)

	token, _ := issuer.Issue("usr_abc")
	tampered := token[:len(token)-2] + "xx"
	if _, err := issuer.Verify(tampered); err != ErrUnauthorized {
		t.Fatalf("tampered token: got %v, want ErrUnauthorized", err)
	}
	foreign, _ := other.Issue("usr_abc")
	if _, err := issuer.Verify(foreign); err != ErrUnauthorized {
		t.Fatalf("foreign token: got %v, want ErrUnauthorized", err)
	}
	if _, err := issuer.Verify("not.a"); err != ErrUnauthorized {
		t.Fatalf("garbage token: got %v, want ErrUnauthorized", err)
	}
}

func TestTokenExpiry(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	issuer := NewTokenIssuer([]byte("test-secret-0123456789abcdef0123"), "i", "a", func() time.Time { return now })
	token, _ := issuer.Issue("usr_x")

	// 31 minutes later: expired (TTL 1h + 30s leeway would not be; use 2h).
	later := now.Add(2 * time.Hour)
	expired := NewTokenIssuer([]byte("test-secret-0123456789abcdef0123"), "i", "a", func() time.Time { return later })
	if _, err := expired.Verify(token); err != ErrUnauthorized {
		t.Fatalf("expired token: got %v, want ErrUnauthorized", err)
	}

	// 30 minutes later: still valid.
	soon := now.Add(30 * time.Minute)
	valid := NewTokenIssuer([]byte("test-secret-0123456789abcdef0123"), "i", "a", func() time.Time { return soon })
	if _, err := valid.Verify(token); err != nil {
		t.Fatalf("live token rejected: %v", err)
	}
}

func TestRegisterAuthenticate(t *testing.T) {
	store := NewStore(nil)
	ctx := context.Background()

	user, err := store.Register(ctx, "  User@Example.COM ", "hunter22boo", "User")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	if user.Email != "user@example.com" {
		t.Fatalf("email not normalized: %q", user.Email)
	}
	if _, err := store.Register(ctx, "user@example.com", "hunter22boo", ""); err != ErrEmailTaken {
		t.Fatalf("duplicate register: got %v, want ErrEmailTaken", err)
	}
	if _, err := store.Register(ctx, "bad-email", "hunter22boo", ""); err == nil {
		t.Fatal("invalid email accepted")
	}
	if _, err := store.Authenticate(ctx, "user@example.com", "hunter22boo"); err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	if _, err := store.Authenticate(ctx, "user@example.com", "wrong"); err != ErrInvalidCredentials {
		t.Fatalf("wrong password: got %v", err)
	}
	if _, err := store.Authenticate(ctx, "ghost@example.com", "whatever1"); err != ErrInvalidCredentials {
		t.Fatalf("unknown user: got %v", err)
	}
}

func TestRefreshRotationAndReuseDetection(t *testing.T) {
	store := NewStore(nil)
	issuer := NewTokenIssuer([]byte("test-secret-0123456789abcdef0123"), "i", "a", nil)
	ctx := context.Background()

	user, err := store.Register(ctx, "rotate@example.com", "hunter22boo", "")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	first, err := store.IssueSession(ctx, user, "dev-1", issuer)
	if err != nil {
		t.Fatalf("IssueSession: %v", err)
	}

	// Another session on another device.
	second, err := store.IssueSession(ctx, user, "dev-2", issuer)
	if err != nil {
		t.Fatalf("IssueSession 2: %v", err)
	}

	rotated, err := store.RotateRefreshToken(ctx, first.RefreshToken, issuer)
	if err != nil {
		t.Fatalf("RotateRefreshToken: %v", err)
	}
	if rotated.RefreshToken == first.RefreshToken {
		t.Fatal("rotation returned the same token")
	}

	// Reuse of the rotated token must revoke every session of the user.
	if _, err := store.RotateRefreshToken(ctx, first.RefreshToken, issuer); err != ErrUnauthorized {
		t.Fatalf("reuse: got %v, want ErrUnauthorized", err)
	}
	if _, err := store.RotateRefreshToken(ctx, rotated.RefreshToken, issuer); err != ErrUnauthorized {
		t.Fatal("revoked session still usable")
	}
	if _, err := store.RotateRefreshToken(ctx, second.RefreshToken, issuer); err != ErrUnauthorized {
		t.Fatal("second device session survived reuse detection")
	}
}

func TestRefreshUnknownTokenRejected(t *testing.T) {
	store := NewStore(nil)
	issuer := NewTokenIssuer([]byte("test-secret-0123456789abcdef0123"), "i", "a", nil)
	if _, err := store.RotateRefreshToken(context.Background(), "nope", issuer); err != ErrUnauthorized {
		t.Fatalf("unknown refresh token: got %v", err)
	}
}

func TestLogoutRevokesOnlyOwnToken(t *testing.T) {
	store := NewStore(nil)
	issuer := NewTokenIssuer([]byte("test-secret-0123456789abcdef0123"), "i", "a", nil)
	ctx := context.Background()
	user, _ := store.Register(ctx, "logout@example.com", "hunter22boo", "")
	first, _ := store.IssueSession(ctx, user, "", issuer)
	second, _ := store.IssueSession(ctx, user, "", issuer)

	store.RevokeRefreshToken(ctx, first.RefreshToken)
	if _, err := store.RotateRefreshToken(ctx, first.RefreshToken, issuer); err != ErrUnauthorized {
		t.Fatal("logged-out token still rotates")
	}
	if _, err := store.RotateRefreshToken(ctx, second.RefreshToken, issuer); err != nil {
		t.Fatalf("other token revoked by logout: %v", err)
	}
}

func TestDeviceRegistry(t *testing.T) {
	store := NewStore(nil)
	ctx := context.Background()
	user, _ := store.Register(ctx, "devices@example.com", "hunter22boo", "")

	devices, err := store.RegisterDevice(ctx, user.ID, "phone-1", "Pixel", "android")
	if err != nil {
		t.Fatalf("RegisterDevice: %v", err)
	}
	if len(devices) != 1 || devices[0].ID != "phone-1" {
		t.Fatalf("unexpected device list: %+v", devices)
	}

	// Upsert: same id updates instead of duplicating.
	if _, err := store.RegisterDevice(ctx, user.ID, "phone-1", "Pixel 9", "android"); err != nil {
		t.Fatalf("re-register: %v", err)
	}
	if devices = store.Devices(ctx, user.ID); len(devices) != 1 || devices[0].Name != "Pixel 9" {
		t.Fatalf("upsert failed: %+v", devices)
	}

	if _, err := store.RegisterDevice(ctx, user.ID, "", "x", ""); err == nil {
		t.Fatal("empty device id accepted")
	}
	if err := store.RevokeDevice(ctx, user.ID, "missing"); err == nil {
		t.Fatal("revoking unknown device succeeded")
	}
	if _, err := store.RegisterDevice(ctx, user.ID, "tablet-1", "iPad", "ios"); err != nil {
		t.Fatalf("RegisterDevice 2: %v", err)
	}
	if err := store.RevokeDevice(ctx, user.ID, "tablet-1"); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}
	if devices = store.Devices(ctx, user.ID); len(devices) != 1 {
		t.Fatalf("devices after revoke: %+v", devices)
	}
}
