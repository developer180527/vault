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
			// Jobs (M3), files/backup (M4-M5) land here.
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
