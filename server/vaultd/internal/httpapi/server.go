// Package httpapi wires vaultd's routes and middleware. The route table is the
// server side of the client's VaultClient contract; endpoints land here across
// M2–M5.
package httpapi

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/files"
	"github.com/developer180527/vault/vaultd/internal/jobs"
	"github.com/developer180527/vault/vaultd/internal/music"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// Options are the dependencies the server needs.
type Options struct {
	Log   *slog.Logger
	Store *store.Store

	// Verifier validates OIDC ID tokens (nil until Pocket ID is configured —
	// auth endpoints then answer 503 instead of crashing the rest).
	Verifier auth.Verifier

	// SetupCode enables the one-time bootstrap endpoint. Empty = disabled
	// (users already exist).
	SetupCode string

	// OIDCIssuer/OIDCClientID are served to clients via /v1/auth/config so
	// the app discovers how to log in without hardcoding either.
	OIDCIssuer   string
	OIDCClientID string

	// DataRoot is /srv/vault — per-user libraries are ensured under it at
	// enrollment.
	DataRoot string

	// Jobs is the background-work engine (nil disables the jobs API).
	Jobs *jobs.Engine
}

// Server holds the dependencies shared by handlers.
type Server struct {
	log          *slog.Logger
	store        *store.Store
	verifier     auth.Verifier
	setupCode    string
	setupMu      sync.Mutex
	oidcIssuer   string
	oidcClientID string
	dataRoot     string
	jobs         *jobs.Engine
	files        *files.Service
	music        *music.Service
}

// New builds the router.
func New(o Options) http.Handler {
	s := &Server{
		log:          o.Log,
		store:        o.Store,
		verifier:     o.Verifier,
		setupCode:    o.SetupCode,
		oidcIssuer:   o.OIDCIssuer,
		oidcClientID: o.OIDCClientID,
		dataRoot:     o.DataRoot,
		jobs:         o.Jobs,
		files:        &files.Service{DataRoot: o.DataRoot},
		music: &music.Service{
			DataRoot: o.DataRoot, Store: o.Store, Log: o.Log},
	}
	// The shared catalog directory must exist before the admin's first drop.
	if err := s.music.EnsureCatalog(); err != nil {
		o.Log.Warn("catalog dir", "err", err)
	}

	r := chi.NewRouter()
	r.Use(RequestID)
	r.Use(Logger(o.Log))

	r.Get("/healthz", s.health)

	r.Route("/v1", func(r chi.Router) {
		// Unauthenticated: login discovery, enrollment, token lifecycle.
		r.Get("/auth/config", s.handleAuthConfig)
		r.Post("/setup", s.handleSetup)
		r.Post("/devices/register", s.handleRegister)
		r.Post("/token", s.handleToken)

		// Authenticated.
		r.Group(func(r chi.Router) {
			r.Use(s.RequireAuth)
			r.Get("/manifest", s.handleManifest)

			// Jobs — torrent and downloads are separate services sharing one
			// pipeline. Grants are checked per-request by job KIND inside the
			// handlers (torrent:write for magnets, downloads:write for URLs),
			// not at the route, so one endpoint serves both.
			r.Get("/jobs/watch", s.handleWatchJobs)
			r.Post("/jobs", s.handleSubmitJob)
			r.Post("/jobs/{id}/cancel", s.handleCancelJob)
			r.Post("/jobs/{id}/retry", s.handleRetryJob)
			r.Post("/jobs/clear-finished", s.handleClearFinished)

			// Files — browse/stream on files:read, mutate on write/delete.
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("files", "read"))
				r.Get("/files", s.handleListFiles)
				r.Get("/files/path", s.handleFilePath)
				r.Get("/files/{id}/content", s.handleFileContent)
			})
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("files", "write"))
				r.Post("/files/folder", s.handleMkdir)
				r.Post("/files/rename", s.handleRenameFile)
				r.Post("/files/upload", s.handleUpload)
			})
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("files", "delete"))
				r.Post("/files/trash", s.handleTrashFile)
			})

			// Music — per-user zone endpoints (docs/MUSIC.md), untouched for
			// compatibility, plus the shared admin-curated catalog: members
			// stream/search on music:read; only music:write (admin) mutates
			// the catalog. Playlists and listens are per-user data keyed by
			// catalog UUIDs.
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("music", "read"))
				r.Get("/music/tracks", s.handleListTracks)
				r.Get("/music/search", s.handleSearchTracks)
				r.Get("/music/tracks/{id}/stream", s.handleStreamTrack)
				r.Get("/music/tracks/{id}/art", s.handleTrackArt)

				r.Get("/music/catalog", s.handleCatalog)
				r.Get("/music/catalog/{id}/stream", s.handleCatalogStream)
				r.Get("/music/catalog/{id}/art", s.handleCatalogArt)

				r.Get("/music/playlists", s.handleListPlaylists)
				r.Post("/music/playlists", s.handleCreatePlaylist)
				r.Delete("/music/playlists/{id}", s.handleDeletePlaylist)
				r.Get("/music/playlists/{id}/tracks", s.handlePlaylistTracks)
				r.Post("/music/playlists/{id}/tracks", s.handleAddToPlaylist)
				r.Delete("/music/playlists/{id}/tracks/{trackId}", s.handleRemoveFromPlaylist)

				r.Post("/music/listens", s.handleReportListen)
			})
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("music", "write"))
				r.Patch("/music/catalog/{id}", s.handleCatalogEdit)
				r.Post("/music/catalog/scan", s.handleCatalogScan)
			})
			// backup (M4) lands here.
		})
	})

	return r
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "ok",
		"service": "vaultd",
	})
}

// fail logs an internal error with the request id and answers 500 without
// leaking details.
func (s *Server) fail(w http.ResponseWriter, r *http.Request, err error) {
	s.log.Error("internal", "id", RequestIDFrom(r.Context()), "err", err)
	writeErr(w, http.StatusInternalServerError, "internal error")
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"error": msg})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
