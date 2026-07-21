// Package httpapi wires vaultd's routes and middleware. The route table is the
// server side of the client's VaultClient contract; endpoints land here across
// M2–M5.
package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"path/filepath"
	"sync"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/files"
	"github.com/developer180527/vault/vaultd/internal/jobs"
	"github.com/developer180527/vault/vaultd/internal/movies"
	"github.com/developer180527/vault/vaultd/internal/music"
	"github.com/developer180527/vault/vaultd/internal/photos"
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

	// PhotosRoot is the camera-backup store (its own filesystem in prod —
	// the HDD pool). Empty → defaults under DataRoot.
	PhotosRoot string

	// MoviesRoot / FFmpeg paths drive the movie catalog (scan + streaming).
	MoviesRoot    string
	FFmpegBinary  string
	FFprobeBinary string

	// Jobs is the background-work engine (nil disables the jobs API).
	Jobs *jobs.Engine

	// Signer mints/verifies signed stream URLs (nil → lists carry no
	// stream_url and streams are bearer-only, the pre-signing behavior).
	Signer *auth.StreamSigner
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
	photos       *photos.Service
	movies       *movies.Service
	signer       *auth.StreamSigner
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
		signer:       o.Signer,
		files:        &files.Service{DataRoot: o.DataRoot},
		music: &music.Service{
			DataRoot: o.DataRoot, Store: o.Store, Log: o.Log},
	}
	photosRoot := o.PhotosRoot
	if photosRoot == "" {
		photosRoot = filepath.Join(o.DataRoot, "photos")
	}
	s.photos = &photos.Service{Root: photosRoot}
	// Uploads interrupted by a restart leave .part orphans; no upload can be
	// live before the listener starts, so booting is the safe sweep moment.
	if n := s.photos.SweepPartials(); n > 0 {
		o.Log.Info("swept stale partial uploads", "count", n)
	}
	go s.checkPhotoIntegrity(context.Background())

	moviesRoot := o.MoviesRoot
	if moviesRoot == "" {
		moviesRoot = filepath.Join(o.DataRoot, "catalog", "movies")
	}
	s.movies = &movies.Service{
		Root: moviesRoot, Store: o.Store, Log: o.Log,
		Prober:     movies.FFprobe{Bin: o.FFprobeBinary},
		FFmpegPath: o.FFmpegBinary,
	}
	if err := s.movies.EnsureRoot(); err != nil {
		o.Log.Warn("movies dir", "err", err)
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

		// Streams sit OUTSIDE the auth middleware: they accept a signed URL
		// (minted per track at list time, so playback outlives the 15-minute
		// bearer) or fall back to bearer + grant inside the handler.
		r.Get("/music/tracks/{id}/stream", s.handleStreamTrack)
		r.Get("/music/catalog/{id}/stream", s.handleCatalogStream)
		// Movie stream: signed-URL or bearer inside the handler (like music).
		r.Get("/movies/{id}/stream", s.handleMovieStream)

		// Authenticated.
		r.Group(func(r chi.Router) {
			r.Use(s.RequireAuth)
			r.Get("/manifest", s.handleManifest)

			// Profile picture — every user owns exactly their own.
			r.Get("/me/avatar", s.handleGetMyAvatar)
			r.Put("/me/avatar", s.handlePutMyAvatar)

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
				r.Get("/synced-folders", s.handleListSyncedFolders)
			})
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("files", "write"))
				r.Post("/files/folder", s.handleMkdir)
				r.Post("/files/rename", s.handleRenameFile)
				r.Post("/files/upload", s.handleUpload)
				// Sync folders — a folder pushed from a device, browsable
				// everywhere (files land via the upload path above).
				r.Post("/synced-folders", s.handleCreateSyncedFolder)
				r.Post("/synced-folders/{id}/touch", s.handleTouchSyncedFolder)
				r.Delete("/synced-folders/{id}", s.handleDeleteSyncedFolder)
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
				r.Get("/music/tracks/{id}/art", s.handleTrackArt)

				r.Get("/music/catalog", s.handleCatalog)
				r.Get("/music/catalog/{id}/art", s.handleCatalogArt)

				r.Get("/music/playlists", s.handleListPlaylists)
				r.Post("/music/playlists", s.handleCreatePlaylist)
				r.Delete("/music/playlists/{id}", s.handleDeletePlaylist)
				r.Get("/music/playlists/{id}/tracks", s.handlePlaylistTracks)
				r.Post("/music/playlists/{id}/tracks", s.handleAddToPlaylist)
				r.Delete("/music/playlists/{id}/tracks/{trackId}", s.handleRemoveFromPlaylist)

				r.Post("/music/listens", s.handleReportListen)

				// "You" shelf + per-user liked songs over the shared catalog.
				r.Get("/music/you/most-played", s.handleMostPlayed)
				r.Get("/music/favorites", s.handleListFavorites)
				r.Put("/music/favorites/{id}", s.handleAddFavorite)
				r.Delete("/music/favorites/{id}", s.handleRemoveFavorite)
			})
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("music", "write"))
				r.Patch("/music/catalog/{id}", s.handleCatalogEdit)
				r.Post("/music/catalog/scan", s.handleCatalogScan)
			})

			// Photos — camera-roll backup (M3 simple phase). The sync action
			// gates the backup engine (check+upload); read serves the
			// listing and originals back.
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("photos", "sync"))
				r.Post("/photos/check", s.handlePhotosCheck)
				r.Post("/photos", s.handlePhotoUpload)
				r.Get("/photos/missing-thumbs", s.handleMissingThumbs)
				r.Put("/photos/{id}/thumb", s.handleSetPhotoThumb)
			})
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("photos", "read"))
				r.Get("/photos", s.handleListPhotos)
				r.Get("/photos/{id}/content", s.handlePhotoContent)
				r.Get("/photos/{id}/thumb", s.handlePhotoThumb)
			})

			// Movies — shared catalog (docs/MOVIES.md). Members browse/stream
			// on movies:read; only movies:write (admin) scans and edits.
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("movies", "read"))
				r.Get("/movies", s.handleMovies)
				r.Get("/movies/continue", s.handleContinueWatching)
				r.Get("/movies/{id}", s.handleMovieDetail)
				r.Get("/movies/{id}/art", s.handleMovieArt)
				r.Get("/movies/{id}/subs/{track}", s.handleMovieSubs)
				r.Post("/movies/{id}/watches", s.handleRecordWatch)
			})
			r.Group(func(r chi.Router) {
				r.Use(s.RequireGrant("movies", "write"))
				r.Patch("/movies/{id}", s.handleMovieEdit)
				r.Post("/movies/scan", s.handleMovieScan)
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
