// Package adminweb is the tailnet-only admin panel: server-rendered pages
// served by vaultd on a SEPARATE listener, reachable only through the
// admin-restricted Tailscale port (docs/backend/ADMIN.md).
//
// Security model, in one paragraph: the listener is network-gated to admin
// devices by the Tailscale ACL; identity is Pocket ID via a standard
// Authorization-Code+PKCE browser flow (same public client as the app, one
// extra redirect URI); vaultd maps the verified identity to a user by the
// SAME (issuer, subject) binding the app uses and admits only active admins;
// the session is an opaque random cookie stored sha256-hashed with a 12h
// absolute expiry; role/status are re-checked on EVERY request, so demotion
// takes effect on the next click; mutations additionally require a
// same-origin fetch-metadata/Origin match. Zero JavaScript in Phase 0.
package adminweb

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/changes"
	"github.com/developer180527/vault/vaultd/internal/movies"
	"github.com/developer180527/vault/vaultd/internal/music"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// Options wires the panel's dependencies.
type Options struct {
	Log   *slog.Logger
	Store *store.Store

	// Music powers the catalog manager (scan / artwork / trash-delete).
	Music *music.Service

	// Movies powers the movie catalog manager (scan / metadata / poster).
	Movies *movies.Service

	// PhotosRoot is the camera-backup store (the HDD pool in prod). Its
	// volume shows on the System page beside the data volume. Empty = same
	// volume, no separate card.
	PhotosRoot string

	// ExternalURL is how the ADMIN'S BROWSER reaches the panel, e.g.
	// https://vault-server.<tailnet>.ts.net:8444 — used for the OAuth
	// redirect URI and the same-origin mutation check.
	ExternalURL string

	// Flow runs the OIDC dance (tests inject a fake).
	Flow OAuthFlow

	// Changes is the app-facing change hub: panel mutations bump it so
	// connected apps refresh without a restart. Nil-safe (tests omit it).
	Changes *changes.Hub
}

const (
	sessionCookie = "vault_admin"
	oauthCookie   = "vault_admin_oauth"
	sessionTTL    = 12 * time.Hour
)

type Server struct {
	log        *slog.Logger
	store      *store.Store
	music      *music.Service
	movies     *movies.Service
	photosRoot string
	flow       OAuthFlow
	external   *url.URL
	changes    *changes.Hub
}

// New builds the admin panel handler.
func New(o Options) (http.Handler, error) {
	ext, err := url.Parse(o.ExternalURL)
	if err != nil {
		return nil, err
	}
	s := &Server{
		log: o.Log, store: o.Store, music: o.Music, movies: o.Movies,
		photosRoot: o.PhotosRoot, flow: o.Flow, external: ext,
		changes: o.Changes,
	}

	r := chi.NewRouter()
	r.Use(s.secureHeaders)
	r.Get("/login", s.handleLoginPage)
	r.Get("/login/start", s.handleLoginStart)
	r.Get("/oauth/callback", s.handleCallback)

	// Authenticated pages. requireAdmin re-checks role/status per request and
	// enforces same-origin on every mutation.
	r.Group(func(r chi.Router) {
		r.Use(s.requireAdmin)
		r.Get("/", s.handleOverview)
		r.Post("/logout", s.handleLogout)

		// Phase 1 — Users & grants.
		r.Get("/users", s.handleUsers)
		r.Get("/users/{id}/avatar", s.handleUserAvatar)
		r.Post("/users", s.handleCreateInvite)
		r.Get("/users/{id}", s.handleUserDetail)
		r.Post("/users/{id}/grants", s.handleSaveGrants)
		r.Post("/users/{id}/status", s.handleSetStatus)
		r.Post("/users/{id}/role", s.handleSetRole)
		r.Post("/users/{id}/devices/{deviceID}/revoke", s.handleRevokeDevice)

		// Phase 1 — Catalog manager.
		r.Get("/catalog", s.handleCatalog)
		r.Post("/catalog/scan", s.handleCatalogScan)
		r.Post("/catalog/optimize", s.handleCatalogOptimize)
		r.Post("/catalog/upload", s.handleCatalogUpload)
		r.Get("/catalog/{id}", s.handleTrackEditPage)
		r.Post("/catalog/{id}", s.handleTrackSave)
		r.Post("/catalog/{id}/delete", s.handleTrackDelete)
		r.Get("/catalog/{id}/art", s.handleTrackArt)
		r.Post("/catalog/{id}/art", s.handleTrackArtUpload)

		// Movie catalog manager (docs/MOVIES.md). No browser upload — movie
		// files are large; copy to /srv/vault/movies then Scan.
		r.Get("/movies", s.handleMovieCatalog)
		r.Post("/movies/scan", s.handleMovieCatalogScan)
		r.Post("/movies/upload", s.handleMovieUpload)
		r.Get("/movies/{id}", s.handleMovieEditPage)
		r.Post("/movies/{id}", s.handleMovieSave)
		r.Post("/movies/{id}/delete", s.handleMovieDelete)
		r.Get("/movies/{id}/art", s.handleMoviePoster)
		r.Post("/movies/{id}/art", s.handleMoviePosterUpload)

		// Phase 4 — Insights (listen analytics, read-only).
		r.Get("/insights", s.handleInsights)
		// Phase 2 — Activity (append-only audit feed).
		r.Get("/activity", s.handleActivity)

		// Phase 3 — System (read-only host/data metrics).
		r.Get("/system", s.handleSystem)
	})
	return r, nil
}

// secureHeaders: strict CSP (no scripts at all in Phase 0), no framing, no
// sniffing, no referrer leakage beyond the panel.
func (s *Server) secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy",
			"default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "same-origin")
		next.ServeHTTP(w, r)
	})
}

// ---- auth flow ----

// oauthState is what the short-lived HttpOnly cookie carries between
// /login/start and the callback. None of it is a credential: state/nonce are
// one-time correlation values and the PKCE verifier is useless without our
// client's code.
type oauthState struct {
	State    string `json:"state"`
	Nonce    string `json:"nonce"`
	Verifier string `json:"verifier"`
}

func randomToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func (s *Server) handleLoginPage(w http.ResponseWriter, r *http.Request) {
	// Already signed in → straight to the panel.
	if _, err := s.sessionUser(r); err == nil {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}
	s.render(w, "login.html", map[string]any{})
}

func (s *Server) handleLoginStart(w http.ResponseWriter, r *http.Request) {
	st := oauthState{
		State:    randomToken(),
		Nonce:    randomToken(),
		Verifier: randomToken(), // 43-char base64url — valid PKCE verifier
	}
	dest, err := s.flow.AuthCodeURL(r.Context(), st.State, st.Nonce, st.Verifier)
	if err != nil {
		s.log.Warn("admin login: authorize URL", "err", err)
		s.renderError(w, http.StatusServiceUnavailable,
			"The identity provider is unreachable. Try again in a moment.")
		return
	}
	raw, _ := json.Marshal(st)
	http.SetCookie(w, &http.Cookie{
		Name:  oauthCookie,
		Value: base64.RawURLEncoding.EncodeToString(raw),
		Path:  "/",
		// Lax (not Strict): the callback arrives as a top-level navigation
		// from Pocket ID and must still carry this cookie.
		SameSite: http.SameSiteLaxMode,
		HttpOnly: true,
		Secure:   true,
		MaxAge:   600,
	})
	http.Redirect(w, r, dest, http.StatusFound)
}

func (s *Server) handleCallback(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Recover and burn the flow cookie — each attempt is single-use.
	c, err := r.Cookie(oauthCookie)
	if err != nil {
		s.renderError(w, http.StatusBadRequest,
			"Login attempt expired. Start again.")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name: oauthCookie, Path: "/", MaxAge: -1, HttpOnly: true, Secure: true})
	var st oauthState
	if raw, err := base64.RawURLEncoding.DecodeString(c.Value); err != nil ||
		json.Unmarshal(raw, &st) != nil {
		s.renderError(w, http.StatusBadRequest, "Malformed login state.")
		return
	}
	if q := r.URL.Query().Get("state"); q == "" || q != st.State {
		s.renderError(w, http.StatusBadRequest,
			"Login state mismatch. Start again.")
		return
	}

	rawIDToken, err := s.flow.Exchange(ctx, r.URL.Query().Get("code"), st.Verifier)
	if err != nil {
		s.log.Warn("admin login: exchange", "err", err)
		s.renderError(w, http.StatusBadGateway, "Could not complete sign-in.")
		return
	}
	ident, nonce, err := s.flow.VerifyIDToken(ctx, rawIDToken)
	if err != nil || nonce != st.Nonce {
		s.log.Warn("admin login: id_token", "err", err, "nonceOK", nonce == st.Nonce)
		s.renderError(w, http.StatusForbidden, "Sign-in could not be verified.")
		return
	}

	// Same identity binding as the app path; only active admins get in.
	user, err := s.store.Read().UserByOIDC(ctx, ident.Issuer, ident.Subject)
	if err != nil || user.Status != "active" || user.Role != "admin" {
		s.log.Warn("admin login refused",
			"subject", ident.Subject, "err", err)
		s.renderError(w, http.StatusForbidden,
			"This account is not a Vault admin.")
		return
	}

	token, hash := auth.NewToken()
	_ = s.store.Write().PruneAdminSessions(ctx, time.Now())
	if err := s.store.Write().CreateAdminSession(
		ctx, user.ID, hash, time.Now().Add(sessionTTL)); err != nil {
		s.log.Error("admin session create", "err", err)
		s.renderError(w, http.StatusInternalServerError, "Internal error.")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    token,
		Path:     "/",
		SameSite: http.SameSiteStrictMode,
		HttpOnly: true,
		Secure:   true,
		MaxAge:   int(sessionTTL.Seconds()),
	})
	s.log.Info("admin signed in", "user", user.Username)
	http.Redirect(w, r, "/", http.StatusFound)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookie); err == nil {
		_ = s.store.Write().DeleteAdminSession(
			r.Context(), auth.HashToken(c.Value))
	}
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookie, Path: "/", MaxAge: -1, HttpOnly: true, Secure: true})
	http.Redirect(w, r, "/login", http.StatusFound)
}

// ---- session middleware ----

type ctxKey struct{}

func (s *Server) sessionUser(r *http.Request) (*store.User, error) {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return nil, err
	}
	u, err := s.store.Read().AdminSessionUser(
		r.Context(), auth.HashToken(c.Value), time.Now())
	if err != nil {
		return nil, err
	}
	// Re-checked per request: demote or disable an admin and their next
	// click is a login page, not their next login.
	if u.Status != "active" || u.Role != "admin" {
		return nil, store.ErrNotFound
	}
	return u, nil
}

func (s *Server) requireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, err := s.sessionUser(r)
		if err != nil {
			http.Redirect(w, r, "/login", http.StatusFound)
			return
		}
		// Same-origin guard on mutations. Sec-Fetch-Site is sent by every
		// current browser; Origin is the fallback. A request carrying
		// neither is not a browser form post — reject.
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if !s.sameOrigin(r) {
				http.Error(w, "cross-origin request refused", http.StatusForbidden)
				return
			}
		}
		next.ServeHTTP(w, r.WithContext(
			context.WithValue(r.Context(), ctxKey{}, user)))
	})
}

func (s *Server) sameOrigin(r *http.Request) bool {
	switch r.Header.Get("Sec-Fetch-Site") {
	case "same-origin", "none":
		return true
	case "":
		// No fetch metadata → require a matching Origin header.
		o, err := url.Parse(r.Header.Get("Origin"))
		return err == nil && r.Header.Get("Origin") != "" &&
			strings.EqualFold(o.Host, s.external.Host) &&
			o.Scheme == s.external.Scheme
	default:
		return false // cross-site / same-site-but-different-origin
	}
}

func userFrom(r *http.Request) *store.User {
	u, _ := r.Context().Value(ctxKey{}).(*store.User)
	return u
}

// ---- pages ----

func (s *Server) handleOverview(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	users, _ := s.store.Read().CountUsers(ctx)
	tracks, _ := s.store.Read().CatalogTracks(ctx)
	s.render(w, "overview.html", map[string]any{
		"User":          userFrom(r),
		"Active":        "overview",
		"UserCount":     users,
		"CatalogTracks": len(tracks),
	})
}
