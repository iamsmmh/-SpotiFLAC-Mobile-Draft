package marketplace

import (
	"context"
	"encoding/json"
	stderrors "errors"
	"net/http"
	"strconv"
)

// Handler serves the /v1/marketplace/* endpoints.
type Handler struct {
	svc *Service
}

// NewHandler creates a new marketplace handler.
func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

// MiddlewareFunc is the signature for auth middleware.
type MiddlewareFunc func(http.HandlerFunc) http.HandlerFunc

// Routes registers marketplace endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth MiddlewareFunc) {
	mux.HandleFunc("GET /v1/marketplace/extensions", h.search)
	mux.HandleFunc("GET /v1/marketplace/extensions/{id}", h.getExtension)
	mux.HandleFunc("POST /v1/marketplace/extensions/{id}/install", auth(h.install))
	mux.HandleFunc("DELETE /v1/marketplace/extensions/{id}/install", auth(h.uninstall))
	mux.HandleFunc("GET /v1/marketplace/extensions/{id}/reviews", h.getReviews)
	mux.HandleFunc("POST /v1/marketplace/extensions/{id}/reviews", auth(h.addReview))
	mux.HandleFunc("GET /v1/marketplace/updates", auth(h.checkUpdates))
	mux.HandleFunc("GET /v1/marketplace/extensions/{id}/dependencies", h.getDependencies)
}

func (h *Handler) search(w http.ResponseWriter, r *http.Request) {
	req := SearchRequest{
		Query:    r.URL.Query().Get("q"),
		Category: r.URL.Query().Get("category"),
		Sort:     r.URL.Query().Get("sort"),
	}
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			req.Limit = n
		}
	}
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			req.Offset = n
		}
	}
	extensions, err := h.svc.Search(r.Context(), req)
	if err != nil {
		writeMarketError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(extensions)
}

func (h *Handler) getExtension(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	ext, err := h.svc.GetExtension(r.Context(), id)
	if err != nil {
		writeMarketError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(ext)
}

func (h *Handler) install(w http.ResponseWriter, r *http.Request) {
	userID := mktUserFromCtx(r.Context())
	id := r.PathValue("id")
	var body struct {
		Version string `json:"version"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if err := h.svc.InstallExtension(r.Context(), id, userID, body.Version); err != nil {
		writeMarketError(w, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

func (h *Handler) uninstall(w http.ResponseWriter, r *http.Request) {
	userID := mktUserFromCtx(r.Context())
	id := r.PathValue("id")
	if err := h.svc.UninstallExtension(r.Context(), id, userID); err != nil {
		writeMarketError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) getReviews(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	limit := 20
	offset := 0
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			offset = n
		}
	}
	reviews, err := h.svc.GetReviews(r.Context(), id, limit, offset)
	if err != nil {
		writeMarketError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(reviews)
}

func (h *Handler) addReview(w http.ResponseWriter, r *http.Request) {
	userID := mktUserFromCtx(r.Context())
	id := r.PathValue("id")
	var body struct {
		Rating int    `json:"rating"`
		Text   string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	if err := h.svc.AddReview(r.Context(), id, userID, body.Rating, body.Text); err != nil {
		writeMarketError(w, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

func (h *Handler) checkUpdates(w http.ResponseWriter, r *http.Request) {
	userID := mktUserFromCtx(r.Context())
	updates, err := h.svc.CheckUpdates(r.Context(), userID)
	if err != nil {
		writeMarketError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(updates)
}

func (h *Handler) getDependencies(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	deps, err := h.svc.ResolveDependencies(r.Context(), id)
	if err != nil {
		writeMarketError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(deps)
}

type marketContextKey string

const marketUserKey marketContextKey = "user_id"

func mktUserFromCtx(ctx context.Context) string {
	v, _ := ctx.Value(marketUserKey).(string)
	return v
}

// WithUserID adds the user ID to the context.
func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, marketUserKey, userID)
}

func writeMarketError(w http.ResponseWriter, err error) {
	switch {
	case stderrors.Is(err, ErrNotFound):
		http.Error(w, err.Error(), http.StatusNotFound)
	case stderrors.Is(err, ErrInvalidInput):
		http.Error(w, err.Error(), http.StatusBadRequest)
	case stderrors.Is(err, ErrAlreadyExists):
		http.Error(w, err.Error(), http.StatusConflict)
	default:
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}
