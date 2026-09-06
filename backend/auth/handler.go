package auth

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/zarz/spotiflac_android/backend/internal/httpx"
)

// Handler serves the /v1/auth/* endpoints.
type Handler struct {
	store  *Store
	tokens *TokenIssuer
}

// NewHandler wires the auth handler.
func NewHandler(store *Store, tokens *TokenIssuer) *Handler {
	return &Handler{store: store, tokens: tokens}
}

// Store exposes the backing store (used by the sync middleware wiring).
func (h *Handler) Store() *Store { return h.store }

// Tokens exposes the token issuer.
func (h *Handler) Tokens() *TokenIssuer { return h.tokens }

type registerRequest struct {
	Email       string `json:"email"`
	Password    string `json:"password"`
	DisplayName string `json:"displayName"`
	DeviceID    string `json:"deviceId"`
	DeviceName  string `json:"deviceName"`
	Platform    string `json:"platform"`
}

// deviceMeta carries the optional per-request device registration fields.
type deviceMeta struct {
	deviceID   string
	deviceName string
	platform   string
}

type loginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	DeviceID string `json:"deviceId"`
}

type refreshRequest struct {
	RefreshToken string `json:"refreshToken"`
}

type logoutRequest struct {
	RefreshToken string `json:"refreshToken"`
}

type deviceRequest struct {
	DeviceID string `json:"deviceId"`
	Name     string `json:"name"`
	Platform string `json:"platform"`
}

type devicesResponse struct {
	Devices []*Device `json:"devices"`
}

type statusResponse struct {
	Status string `json:"status"`
}

func (h *Handler) sessionWithDevice(ctx context.Context, user *User, meta deviceMeta) (*Session, error) {
	session, err := h.store.IssueSession(ctx, user, meta.deviceID, h.tokens)
	if err != nil {
		return nil, err
	}
	if meta.deviceID != "" {
		_, _ = h.store.RegisterDevice(ctx, user.ID, meta.deviceID, meta.deviceName, meta.platform)
	}
	return session, nil
}

// Register handles POST /v1/auth/register.
func (h *Handler) Register(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := httpx.ReadJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	user, err := h.store.Register(r.Context(), req.Email, req.Password, req.DisplayName)
	if err != nil {
		if errors.Is(err, ErrEmailTaken) {
			httpx.WriteError(w, http.StatusConflict, err.Error())
		} else {
			httpx.WriteError(w, http.StatusBadRequest, err.Error())
		}
		return
	}
	session, err := h.sessionWithDevice(r.Context(), user, deviceMeta{
		deviceID:   req.DeviceID,
		deviceName: req.DeviceName,
		platform:   req.Platform,
	})
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "could not create session")
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, session)
}

// Login handles POST /v1/auth/email (the password grant).
func (h *Handler) Login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := httpx.ReadJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	user, err := h.store.Authenticate(r.Context(), req.Email, req.Password)
	if err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, err.Error())
		return
	}
	session, err := h.sessionWithDevice(r.Context(), user, deviceMeta{
		deviceID: req.DeviceID,
	})
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "could not create session")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, session)
}

// Refresh handles POST /v1/auth/refresh.
func (h *Handler) Refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := httpx.ReadJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(req.RefreshToken) == "" {
		httpx.WriteError(w, http.StatusBadRequest, "refreshToken is required")
		return
	}
	session, err := h.store.RotateRefreshToken(r.Context(), req.RefreshToken, h.tokens)
	if err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, "refresh token rejected")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, session)
}

// Logout handles POST /v1/auth/logout.
func (h *Handler) Logout(w http.ResponseWriter, r *http.Request) {
	var req logoutRequest
	if err := httpx.ReadJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	h.store.RevokeRefreshToken(r.Context(), req.RefreshToken)
	httpx.WriteJSON(w, http.StatusOK, statusResponse{Status: "ok"})
}

// Me handles GET /v1/auth/me (bearer auth).
func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, ErrUnauthorized.Error())
		return
	}
	user, err := h.store.UserByID(r.Context(), userID)
	if err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, ErrUnauthorized.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, user)
}

// RegisterDevice handles POST /v1/auth/devices (bearer auth).
func (h *Handler) RegisterDevice(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, ErrUnauthorized.Error())
		return
	}
	var req deviceRequest
	if err := httpx.ReadJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	devices, err := h.store.RegisterDevice(r.Context(), userID, req.DeviceID, req.Name, req.Platform)
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, devicesResponse{Devices: devices})
}

// ListDevices handles GET /v1/auth/devices (bearer auth).
func (h *Handler) ListDevices(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, ErrUnauthorized.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, devicesResponse{Devices: h.store.Devices(r.Context(), userID)})
}

// RevokeDevice handles DELETE /v1/auth/devices/{id} (bearer auth).
func (h *Handler) RevokeDevice(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, ErrUnauthorized.Error())
		return
	}
	deviceID := r.PathValue("id")
	if err := h.store.RevokeDevice(r.Context(), userID, deviceID); err != nil {
		httpx.WriteError(w, http.StatusNotFound, err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, statusResponse{Status: "ok"})
}

// Middleware authenticates the bearer token and injects the user id.
func (h *Handler) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := httpx.BearerToken(r)
		if token == "" {
			httpx.WriteError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		userID, err := h.tokens.Verify(token)
		if err != nil {
			httpx.WriteError(w, http.StatusUnauthorized, "invalid or expired token")
			return
		}
		next.ServeHTTP(w, r.WithContext(httpx.WithUserID(r.Context(), userID)))
	})
}

// Routes registers the auth endpoints on the mux. Public endpoints are
// mounted directly; the /me and /devices group sits behind the middleware.
func (h *Handler) Routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/auth/register", h.Register)
	mux.HandleFunc("POST /v1/auth/email", h.Login)
	mux.HandleFunc("POST /v1/auth/refresh", h.Refresh)
	mux.HandleFunc("POST /v1/auth/logout", h.Logout)
	mux.Handle("GET /v1/auth/me", h.Middleware(http.HandlerFunc(h.Me)))
	mux.Handle("POST /v1/auth/devices", h.Middleware(http.HandlerFunc(h.RegisterDevice)))
	mux.Handle("GET /v1/auth/devices", h.Middleware(http.HandlerFunc(h.ListDevices)))
	mux.Handle("DELETE /v1/auth/devices/{id}", h.Middleware(http.HandlerFunc(h.RevokeDevice)))
}
