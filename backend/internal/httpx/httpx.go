// Package httpx holds the small HTTP plumbing shared by the backend
// packages: JSON envelope helpers, request decoding with a hard size cap,
// and the bearer-token middleware contract.
package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// MaxBodyBytes caps every request body (sync payloads can be large, but not
// that large).
const MaxBodyBytes = 8 << 20 // 8 MiB

// ErrorEnvelope is the wire error shape from docs/API_CONTRACTS.md:
// {"error": {"message": "…"}}.
type ErrorEnvelope struct {
	Error ErrorBody `json:"error"`
}

// ErrorBody carries one human-readable message.
type ErrorBody struct {
	Message string `json:"message"`
}

// WriteJSON serializes v with the given status code.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

// WriteError emits the standard error envelope.
func WriteError(w http.ResponseWriter, status int, message string) {
	WriteJSON(w, status, ErrorEnvelope{Error: ErrorBody{Message: message}})
}

// ReadJSON decodes the request body into dst, enforcing the size cap and
// rejecting trailing garbage.
func ReadJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, MaxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			return fmt.Errorf("request body too large (limit %d bytes)", maxErr.Limit)
		}
		return fmt.Errorf("invalid JSON body: %w", err)
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("invalid JSON body: trailing data after the object")
	}
	return nil
}

type contextKey int

const userIDKey contextKey = 1

// WithUserID stores the authenticated user id in the request context.
func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, userIDKey, userID)
}

// UserIDFrom extracts the authenticated user id (empty when absent).
func UserIDFrom(ctx context.Context) string {
	id, _ := ctx.Value(userIDKey).(string)
	return id
}

// BearerToken extracts the bearer token from the Authorization header.
func BearerToken(r *http.Request) string {
	header := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(header) <= len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(header[len(prefix):])
}
