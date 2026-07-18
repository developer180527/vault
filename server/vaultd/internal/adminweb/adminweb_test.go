package adminweb

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/music"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// fakeFlow plays the IdP: AuthCodeURL echoes params into a fake authorize
// URL; Exchange returns a raw "token" that VerifyIDToken maps to a canned
// identity + the nonce it was minted with.
type fakeFlow struct {
	identity *auth.Identity
	nonce    string // captured from AuthCodeURL, replayed by VerifyIDToken
	failName string // non-empty → that step errors
}

func (f *fakeFlow) AuthCodeURL(_ context.Context, state, nonce, verifier string) (string, error) {
	if f.failName == "authorize" {
		return "", fmt.Errorf("idp down")
	}
	f.nonce = nonce
	return "https://idp.example/authorize?state=" + url.QueryEscape(state), nil
}

func (f *fakeFlow) Exchange(_ context.Context, code, verifier string) (string, error) {
	if f.failName == "exchange" || code != "good-code" {
		return "", fmt.Errorf("bad code")
	}
	return "raw-id-token", nil
}

func (f *fakeFlow) VerifyIDToken(_ context.Context, raw string) (*auth.Identity, string, error) {
	if f.failName == "verify" || raw != "raw-id-token" {
		return nil, "", fmt.Errorf("bad token")
	}
	return f.identity, f.nonce, nil
}

type env struct {
	handler http.Handler
	store   *store.Store
	flow    *fakeFlow
	music   *music.Service
}

func newEnv(t *testing.T) *env {
	t.Helper()
	st, err := store.Open(context.Background(),
		filepath.Join(t.TempDir(), "vault.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	flow := &fakeFlow{identity: &auth.Identity{
		Issuer: "https://idp", Subject: "sub-venu",
		Email: "venu@example.com", Username: "venu",
	}}
	svc := &music.Service{
		DataRoot: t.TempDir(),
		Store:    st,
		Log:      slog.New(slog.DiscardHandler),
	}
	h, err := New(Options{
		Log:         slog.New(slog.DiscardHandler),
		Store:       st,
		Music:       svc,
		ExternalURL: "https://vault.example:8444",
		Flow:        flow,
	})
	if err != nil {
		t.Fatal(err)
	}
	return &env{handler: h, store: st, flow: flow, music: svc}
}

func (e *env) seedUser(t *testing.T, username, role, subject string) *store.User {
	t.Helper()
	u, err := e.store.Write().CreateUser(context.Background(),
		username, username+"@example.com", "", role, "https://idp", subject)
	if err != nil {
		t.Fatal(err)
	}
	return u
}

// login drives the full browser dance and returns the session cookie.
func (e *env) login(t *testing.T) *http.Cookie {
	t.Helper()
	// 1. /login/start sets the flow cookie and redirects to the IdP.
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, httptest.NewRequest("GET", "/login/start", nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("login/start = %d", rec.Code)
	}
	flowCookie := rec.Result().Cookies()[0]
	loc, _ := url.Parse(rec.Header().Get("Location"))
	state := loc.Query().Get("state")

	// 2. The IdP "redirects back" with code+state; the flow cookie rides in.
	req := httptest.NewRequest(
		"GET", "/oauth/callback?code=good-code&state="+url.QueryEscape(state), nil)
	req.AddCookie(flowCookie)
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound {
		body, _ := io.ReadAll(rec.Result().Body)
		t.Fatalf("callback = %d %s", rec.Code, body)
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookie && c.Value != "" {
			return c
		}
	}
	t.Fatalf("no session cookie issued")
	return nil
}

func TestAdminLoginFlowAndOverview(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")

	// Unauthenticated / → bounced to login.
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "/login" {
		t.Fatalf("unauthed / = %d → %q", rec.Code, rec.Header().Get("Location"))
	}

	session := e.login(t)

	// Authenticated overview renders with the username.
	req := httptest.NewRequest("GET", "/", nil)
	req.AddCookie(session)
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	body := rec.Body.String()
	if rec.Code != 200 || !strings.Contains(body, "venu") ||
		!strings.Contains(body, "Overview") {
		t.Fatalf("overview = %d %q", rec.Code, body[:min(200, len(body))])
	}

	// CSP is set on every response.
	if !strings.Contains(
		rec.Header().Get("Content-Security-Policy"), "default-src 'none'") {
		t.Fatalf("missing CSP")
	}
}

func TestNonAdminAndDisabledAreRefused(t *testing.T) {
	e := newEnv(t)
	// The flow's subject belongs to a MEMBER: callback refuses, no cookie.
	e.seedUser(t, "maya", "member", "sub-venu")

	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, httptest.NewRequest("GET", "/login/start", nil))
	flowCookie := rec.Result().Cookies()[0]
	loc, _ := url.Parse(rec.Header().Get("Location"))
	req := httptest.NewRequest("GET",
		"/oauth/callback?code=good-code&state="+
			url.QueryEscape(loc.Query().Get("state")), nil)
	req.AddCookie(flowCookie)
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("member callback = %d, want 403", rec.Code)
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == sessionCookie && c.Value != "" {
			t.Fatalf("member got a session cookie")
		}
	}
}

func TestDisabledAdminBouncesMidSession(t *testing.T) {
	e := newEnv(t)
	admin := e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Disable the account AFTER login: the very next request bounces —
	// the role/status re-check is per request, not per login.
	if err := e.store.Write().SetUserStatus(
		context.Background(), admin.ID, "disabled"); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("GET", "/", nil)
	req.AddCookie(session)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "/login" {
		t.Fatalf("disabled admin / = %d, want login redirect", rec.Code)
	}
}

func TestSessionRevocationAndSameOriginGuard(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Cross-site POST (Sec-Fetch-Site: cross-site) is refused even WITH a
	// valid session.
	req := httptest.NewRequest("POST", "/logout", nil)
	req.AddCookie(session)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("cross-site POST = %d, want 403", rec.Code)
	}

	// Same-origin logout succeeds and kills the session.
	req = httptest.NewRequest("POST", "/logout", nil)
	req.AddCookie(session)
	req.Header.Set("Sec-Fetch-Site", "same-origin")
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound {
		t.Fatalf("logout = %d", rec.Code)
	}
	req = httptest.NewRequest("GET", "/", nil)
	req.AddCookie(session)
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "/login" {
		t.Fatalf("post-logout / = %d, want login redirect", rec.Code)
	}

	// Tampered state on callback is refused.
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, httptest.NewRequest("GET", "/login/start", nil))
	flowCookie := rec.Result().Cookies()[0]
	req = httptest.NewRequest(
		"GET", "/oauth/callback?code=good-code&state=evil", nil)
	req.AddCookie(flowCookie)
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("tampered state = %d, want 400", rec.Code)
	}
}
