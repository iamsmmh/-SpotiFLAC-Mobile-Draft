// Package marketplace implements the Extension Marketplace V2 for the
// SpotiFLAC Cloud (Milestone 6).
//
// Features:
//   - Ratings and reviews with aggregation
//   - Screenshots per extension
//   - Verified badge for trusted publishers
//   - Popularity metrics (downloads, active installs)
//   - Auto-update notification via manifest versioning
//   - Dependency resolution
//   - Extension analytics (install/uninstall/crash counts)
//
// Manifest v2 extends v1 with:
//   rating, downloads, verified, dependencies, screenshots
package marketplace

import (
	"context"
	"errors"
	"time"
)

// Errors.
var (
	ErrNotFound      = errors.New("extension not found")
	ErrInvalidInput  = errors.New("invalid input")
	ErrAlreadyExists = errors.New("already exists")
)

// Extension is the marketplace representation of a published extension.
type Extension struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	Version        string    `json:"version"`
	Description    string    `json:"description"`
	AuthorID       string    `json:"authorId"`
	AuthorName     string    `json:"authorName"`
	Verified       bool      `json:"verified"`
	Category       string    `json:"category"`
	DownloadURL    string    `json:"downloadUrl"`
	IconURL        string    `json:"iconUrl"`
	Screenshots    []string  `json:"screenshots"`
	Rating         float64   `json:"rating"`
	RatingCount    int       `json:"ratingCount"`
	Downloads      int64     `json:"downloads"`
	ActiveInstalls int64     `json:"activeInstalls"`
	Dependencies   []string  `json:"dependencies"`
	SizeBytes      int64     `json:"sizeBytes"`
	MinAppVersion  string    `json:"minAppVersion"`
	CreatedAt      time.Time `json:"createdAt"`
	UpdatedAt      time.Time `json:"updatedAt"`
}

// Review is a user's rating + text for an extension.
type Review struct {
	ID          string    `json:"id"`
	ExtensionID string    `json:"extensionId"`
	UserID      string    `json:"userId"`
	Rating      int       `json:"rating"` // 1-5
	Text        string    `json:"text"`
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

// InstallRecord tracks one user's install state.
type InstallRecord struct {
	ExtensionID string    `json:"extensionId"`
	UserID      string    `json:"userId"`
	Version     string    `json:"version"`
	InstalledAt time.Time `json:"installedAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
	Active      bool      `json:"active"`
}

// AnalyticsRecord tracks extension health metrics.
type AnalyticsRecord struct {
	ExtensionID string    `json:"extensionId"`
	Period      string    `json:"period"` // "day", "week", "month"
	Installs    int64     `json:"installs"`
	Uninstalls  int64     `json:"uninstalls"`
	Crashes     int64     `json:"crashes"`
	At          time.Time `json:"at"`
}

// SearchRequest contains filter parameters for marketplace search.
type SearchRequest struct {
	Query    string `json:"query"`
	Category string `json:"category"`
	Sort     string `json:"sort"` // "popularity", "rating", "recent"
	Limit    int    `json:"limit"`
	Offset   int    `json:"offset"`
}

// Store abstracts persistence.
type Store interface {
	// Extension CRUD
	GetExtension(ctx context.Context, id string) (*Extension, error)
	ListExtensions(ctx context.Context, req SearchRequest) ([]*Extension, error)
	PublishExtension(ctx context.Context, ext Extension) error
	UpdateExtension(ctx context.Context, ext Extension) error

	// Reviews
	GetReviews(ctx context.Context, extensionID string, limit, offset int) ([]Review, error)
	AddReview(ctx context.Context, review Review) error
	GetAverageRating(ctx context.Context, extensionID string) (float64, int, error)

	// Installs
	Install(ctx context.Context, record InstallRecord) error
	Uninstall(ctx context.Context, extensionID, userID string) error
	GetUserInstalls(ctx context.Context, userID string) ([]InstallRecord, error)
	CheckUpdates(ctx context.Context, userID string) ([]Extension, error)

	// Analytics
	RecordAnalytics(ctx context.Context, record AnalyticsRecord) error
	GetAnalytics(ctx context.Context, extensionID string, period string) ([]AnalyticsRecord, error)

	// Verification
	SetVerified(ctx context.Context, extensionID string, verified bool) error
}

// Service provides marketplace operations.
type Service struct {
	store Store
}

// NewService creates a new marketplace service.
func NewService(store Store) *Service {
	return &Service{store: store}
}

// Search returns extensions matching the query.
func (s *Service) Search(ctx context.Context, req SearchRequest) ([]*Extension, error) {
	if req.Limit <= 0 {
		req.Limit = 20
	}
	if req.Limit > 100 {
		req.Limit = 100
	}
	return s.store.ListExtensions(ctx, req)
}

// GetExtension returns details for one extension.
func (s *Service) GetExtension(ctx context.Context, id string) (*Extension, error) {
	if id == "" {
		return nil, ErrInvalidInput
	}
	return s.store.GetExtension(ctx, id)
}

// InstallExtension records a user installing an extension.
func (s *Service) InstallExtension(ctx context.Context, extensionID, userID, version string) error {
	if extensionID == "" || userID == "" {
		return ErrInvalidInput
	}
	now := time.Now().UTC()
	record := InstallRecord{
		ExtensionID: extensionID,
		UserID:      userID,
		Version:     version,
		InstalledAt: now,
		UpdatedAt:   now,
		Active:      true,
	}
	return s.store.Install(ctx, record)
}

// UninstallExtension records a user removing an extension.
func (s *Service) UninstallExtension(ctx context.Context, extensionID, userID string) error {
	return s.store.Uninstall(ctx, extensionID, userID)
}

// AddReview adds or updates a review.
func (s *Service) AddReview(ctx context.Context, extensionID, userID string, rating int, text string) error {
	if extensionID == "" || userID == "" {
		return ErrInvalidInput
	}
	if rating < 1 || rating > 5 {
		return ErrInvalidInput
	}
	review := Review{
		ID:          extensionID + ":" + userID,
		ExtensionID: extensionID,
		UserID:      userID,
		Rating:      rating,
		Text:        text,
		CreatedAt:   time.Now().UTC(),
		UpdatedAt:   time.Now().UTC(),
	}
	return s.store.AddReview(ctx, review)
}

// GetReviews returns paginated reviews for an extension.
func (s *Service) GetReviews(ctx context.Context, extensionID string, limit, offset int) ([]Review, error) {
	if limit <= 0 {
		limit = 20
	}
	return s.store.GetReviews(ctx, extensionID, limit, offset)
}

// CheckUpdates returns extensions that have newer versions available.
func (s *Service) CheckUpdates(ctx context.Context, userID string) ([]Extension, error) {
	return s.store.CheckUpdates(ctx, userID)
}

// ResolveDependencies returns the full dependency graph for an extension.
func (s *Service) ResolveDependencies(ctx context.Context, extensionID string) ([]string, error) {
	ext, err := s.store.GetExtension(ctx, extensionID)
	if err != nil {
		return nil, err
	}
	resolved := make([]string, 0, len(ext.Dependencies))
	seen := map[string]bool{extensionID: true}
	for _, dep := range ext.Dependencies {
		if seen[dep] {
			continue
		}
		seen[dep] = true
		resolved = append(resolved, dep)
		// Recurse one level for transitive deps.
		depExt, err := s.store.GetExtension(ctx, dep)
		if err != nil {
			continue
		}
		for _, transDep := range depExt.Dependencies {
			if !seen[transDep] {
				seen[transDep] = true
				resolved = append(resolved, transDep)
			}
		}
	}
	return resolved, nil
}
