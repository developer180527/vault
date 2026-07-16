package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/library"
	"github.com/developer180527/vault/vaultd/internal/store"
)

type principalKeyType int

const principalKey principalKeyType = iota

// PrincipalFrom returns the authenticated caller, or nil.
func PrincipalFrom(ctx context.Context) *store.Principal {
	p, _ := ctx.Value(principalKey).(*store.Principal)
	return p
}

// RequireAuth resolves the Bearer access token to a principal or 401s.
func (s *Server) RequireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if raw == "" || raw == r.Header.Get("Authorization") {
			writeErr(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		p, err := s.store.Read().PrincipalByAccessHash(
			r.Context(), auth.HashToken(raw), time.Now())
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusUnauthorized, "invalid or expired token")
			return
		}
		if err != nil {
			s.fail(w, r, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(
			context.WithValue(r.Context(), principalKey, p)))
	})
}

// RequireGrant gates a route on a (service, action) grant. Admins pass
// everything; members must hold the action. Fail-closed 403, matching the
// client's manifest gating — but this is the real enforcement (the client's
// is only for what to render).
func (s *Server) RequireGrant(service, action string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			p := PrincipalFrom(r.Context())
			if p == nil {
				writeErr(w, http.StatusUnauthorized, "not authenticated")
				return
			}
			if p.Role == "admin" {
				next.ServeHTTP(w, r)
				return
			}
			grants, err := s.store.Read().GrantsForUser(r.Context(), p.UserID)
			if err != nil {
				s.fail(w, r, err)
				return
			}
			for _, a := range grants[service] {
				if a == action {
					next.ServeHTTP(w, r)
					return
				}
			}
			writeErr(w, http.StatusForbidden,
				"missing grant: "+service+":"+action)
		})
	}
}

// handleAuthConfig tells clients how to log in: the OIDC issuer to run the
// PKCE flow against and the client id to use. Public by design — it contains
// nothing secret, and the app can't hardcode either value.
//
// GET /v1/auth/config
func (s *Server) handleAuthConfig(w http.ResponseWriter, r *http.Request) {
	if s.oidcIssuer == "" || s.oidcClientID == "" {
		writeErr(w, http.StatusServiceUnavailable, "OIDC not configured on server")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"issuer":    s.oidcIssuer,
		"client_id": s.oidcClientID,
	})
}

// deviceGrant is the auth payload returned by setup/register/token.
type deviceGrant struct {
	DeviceID     string `json:"device_id"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"` // seconds
}

// handleSetup binds the FIRST admin: one-time code (printed to stdout at
// boot while the users table is empty) + a verified ID token.
//
// POST /v1/setup {code, id_token, username, device_name, platform}
func (s *Server) handleSetup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code       string `json:"code"`
		IDToken    string `json:"id_token"`
		Username   string `json:"username"`
		DeviceName string `json:"device_name"`
		Platform   string `json:"platform"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	if s.setupCode == "" || req.Code != s.setupCode {
		writeErr(w, http.StatusForbidden, "setup unavailable or wrong code")
		return
	}
	id, err := s.verifyIDToken(r.Context(), req.IDToken)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "id token: "+err.Error())
		return
	}

	// Single-shot under concurrency: one process, so a mutex + emptiness
	// re-check is sufficient (and avoids holding a DB transaction across
	// multiple store calls on the single write connection).
	s.setupMu.Lock()
	defer s.setupMu.Unlock()
	n, err := s.store.Read().CountUsers(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if n > 0 {
		writeErr(w, http.StatusConflict, "setup already completed")
		return
	}

	username := library.Sanitize(
		firstNonEmpty(req.Username, id.Username, emailLocal(id.Email)), "admin")
	u, err := s.store.Write().CreateUser(r.Context(), username, id.Email,
		id.Name, "admin", id.Issuer, id.Subject)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if err := library.Ensure(s.dataRoot, u.Username); err != nil {
		s.fail(w, r, err)
		return
	}
	grant, err := s.issueDevice(r.Context(), u.ID, req.DeviceName, req.Platform)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.setupCode = "" // burn the code
	s.log.Info("bootstrap complete", "user", u.Username, "subject", id.Subject)
	writeJSON(w, http.StatusOK, grant)
}

// handleRegister enrolls a device for an existing or invited user.
//
// POST /v1/devices/register {id_token, device_name, platform}
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IDToken    string `json:"id_token"`
		DeviceName string `json:"device_name"`
		Platform   string `json:"platform"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	id, err := s.verifyIDToken(r.Context(), req.IDToken)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "id token: "+err.Error())
		return
	}

	read := s.store.Read()
	u, err := read.UserByOIDC(r.Context(), id.Issuer, id.Subject)
	if errors.Is(err, store.ErrNotFound) && id.Email != "" {
		// Invite binding: admin pre-created this user by email; first login
		// attaches the OIDC identity permanently.
		if pending, perr := read.PendingUserByEmail(r.Context(), id.Email); perr == nil {
			if berr := s.store.Write().BindOIDC(r.Context(), pending.ID, id.Issuer, id.Subject); berr == nil {
				u, err = pending, nil
				s.log.Info("invite bound", "user", pending.Username, "subject", id.Subject)
			}
		}
	}
	if errors.Is(err, store.ErrNotFound) {
		// Fail closed: authenticating with the IdP is NOT authorization to
		// use Vault. The admin must have created this user.
		writeErr(w, http.StatusForbidden, "no vault account for this identity — ask the admin")
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if u.Status != "active" {
		writeErr(w, http.StatusForbidden, "account disabled")
		return
	}

	// Enrollment guarantees the library exists (idempotent) — every
	// data-generating service depends on these fixed zones.
	if err := library.Ensure(s.dataRoot, u.Username); err != nil {
		s.fail(w, r, err)
		return
	}

	grant, err := s.issueDevice(r.Context(), u.ID, req.DeviceName, req.Platform)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, grant)
}

// handleToken refreshes the token pair, with the rotation grace window.
//
// POST /v1/token {refresh_token}
func (s *Server) handleToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.RefreshToken == "" {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	now := time.Now()
	m, err := s.store.Read().MatchRefresh(r.Context(), auth.HashToken(req.RefreshToken))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusUnauthorized, "unknown refresh token")
		return
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}

	if !m.Current && now.Sub(m.RotatedAt) > auth.RotationGrace {
		// A token OLDER than the grace window came back: someone is replaying
		// a stolen secret (or a client is badly broken). Kill the device.
		_ = s.store.Write().RevokeDevice(r.Context(), m.DeviceID)
		s.log.Warn("refresh reuse outside grace — device revoked",
			"device", m.DeviceID, "user", m.UserID)
		writeErr(w, http.StatusUnauthorized, "refresh token reuse detected; device revoked")
		return
	}

	access, accessHash := auth.NewToken()
	refresh, refreshHash := auth.NewToken()
	if err := s.store.Write().RotateTokens(r.Context(), m.DeviceID, m.Current,
		accessHash, now.Add(auth.AccessTTL), refreshHash, now); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, deviceGrant{
		DeviceID:     m.DeviceID,
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresIn:    int64(auth.AccessTTL.Seconds()),
	})
}

// issueDevice creates a device row with a fresh token pair.
func (s *Server) issueDevice(ctx context.Context, userID, name, platform string) (*deviceGrant, error) {
	access, accessHash := auth.NewToken()
	refresh, refreshHash := auth.NewToken()
	d, err := s.store.Write().CreateDevice(ctx, userID, name, platform,
		accessHash, time.Now().Add(auth.AccessTTL), refreshHash)
	if err != nil {
		return nil, err
	}
	return &deviceGrant{
		DeviceID:     d.ID,
		AccessToken:  access,
		RefreshToken: refresh,
		ExpiresIn:    int64(auth.AccessTTL.Seconds()),
	}, nil
}

func (s *Server) verifyIDToken(ctx context.Context, raw string) (*auth.Identity, error) {
	if s.verifier == nil {
		return nil, errors.New("OIDC not configured on server")
	}
	if raw == "" {
		return nil, errors.New("missing id_token")
	}
	return s.verifier.Verify(ctx, raw)
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func emailLocal(email string) string {
	if i := strings.IndexByte(email, '@'); i > 0 {
		return email[:i]
	}
	return ""
}
