package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"

	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// fakeIDP is a minimal OIDC issuer: discovery doc + JWKS + token minting.
type fakeIDP struct {
	issuer string
	key    *rsa.PrivateKey
	srv    *httptest.Server
}

func newFakeIDP(t *testing.T) *fakeIDP {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeIDP{key: key}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                                f.issuer,
			"jwks_uri":                              f.issuer + "/keys",
			"authorization_endpoint":                f.issuer + "/auth",
			"token_endpoint":                        f.issuer + "/token",
			"id_token_signing_alg_values_supported": []string{"RS256"},
		})
	})
	mux.HandleFunc("/keys", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{
			Key: key.Public(), KeyID: "test", Algorithm: "RS256", Use: "sig",
		}}})
	})
	f.srv = httptest.NewServer(mux)
	f.issuer = f.srv.URL
	t.Cleanup(f.srv.Close)
	return f
}

// mint returns a signed ID token for the given subject/email.
func (f *fakeIDP) mint(t *testing.T, sub, email, username string) string {
	t.Helper()
	signer, err := jose.NewSigner(
		jose.SigningKey{Algorithm: jose.RS256, Key: f.key},
		(&jose.SignerOptions{}).WithHeader("kid", "test"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	raw, err := jwt.Signed(signer).Claims(jwt.Claims{
		Issuer:   f.issuer,
		Subject:  sub,
		Audience: jwt.Audience{"vault-app"},
		IssuedAt: jwt.NewNumericDate(now),
		Expiry:   jwt.NewNumericDate(now.Add(time.Hour)),
	}).Claims(map[string]any{
		"email":              email,
		"preferred_username": username,
	}).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// mintUnverified is like mint but stamps email_verified:false, for asserting
// that an unverified email can't bind a pending invite.
func (f *fakeIDP) mintUnverified(t *testing.T, sub, email, username string) string {
	t.Helper()
	signer, err := jose.NewSigner(
		jose.SigningKey{Algorithm: jose.RS256, Key: f.key},
		(&jose.SignerOptions{}).WithHeader("kid", "test"))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	raw, err := jwt.Signed(signer).Claims(jwt.Claims{
		Issuer:   f.issuer,
		Subject:  sub,
		Audience: jwt.Audience{"vault-app"},
		IssuedAt: jwt.NewNumericDate(now),
		Expiry:   jwt.NewNumericDate(now.Add(time.Hour)),
	}).Claims(map[string]any{
		"email":              email,
		"email_verified":     false,
		"preferred_username": username,
	}).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

type testEnv struct {
	handler  http.Handler
	store    *store.Store
	idp      *fakeIDP
	dataRoot string
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	idp := newFakeIDP(t)
	st, err := store.Open(context.Background(),
		filepath.Join(t.TempDir(), "vault.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	verifier, err := auth.NewOIDCVerifier(context.Background(), idp.issuer, "vault-app")
	if err != nil {
		t.Fatalf("verifier: %v", err)
	}
	dataRoot := t.TempDir()
	h := New(Options{
		Log:       slog.New(slog.DiscardHandler),
		Store:     st,
		Verifier:  verifier,
		SetupCode: "cafe1234",
		DataRoot:  dataRoot,
		Signer:    auth.NewStreamSignerForTest([]byte("0123456789abcdef0123456789abcdef")),
	})
	return &testEnv{handler: h, store: st, idp: idp, dataRoot: dataRoot}
}

// call is a tiny JSON request helper.
func (e *testEnv) call(t *testing.T, method, path, bearer string, body any) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	var out map[string]any
	_ = json.NewDecoder(rec.Body).Decode(&out)
	return rec.Code, out
}

func TestAuthLifecycle(t *testing.T) {
	e := newTestEnv(t)
	adminToken := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")

	// Unauthenticated manifest fails closed.
	if code, _ := e.call(t, "GET", "/v1/manifest", "", nil); code != 401 {
		t.Fatalf("manifest without token = %d, want 401", code)
	}

	// Wrong setup code refused.
	if code, _ := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "wrong", "id_token": adminToken}); code != 403 {
		t.Fatal("wrong setup code accepted")
	}

	// Bootstrap the admin.
	code, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": adminToken,
		"device_name": "venus-mbp", "platform": "macos"})
	if code != 200 {
		t.Fatalf("setup = %d %v", code, grant)
	}
	access := grant["access_token"].(string)

	// Enrollment created the admin's library with all fixed zones.
	for _, zone := range []string{"photos", "downloads", "files", "music"} {
		if _, err := os.Stat(filepath.Join(e.dataRoot, "users", "venu", zone)); err != nil {
			t.Fatalf("library zone %s missing after setup: %v", zone, err)
		}
	}

	// Setup is single-shot.
	if code, _ := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": adminToken}); code != 409 && code != 403 {
		t.Fatalf("second setup not refused")
	}

	// Admin manifest: every service, every action.
	code, manifest := e.call(t, "GET", "/v1/manifest", access, nil)
	if code != 200 {
		t.Fatalf("manifest = %d", code)
	}
	caps := manifest["capabilities"].(map[string]any)
	for _, svc := range store.KnownServices {
		if _, ok := caps[svc]; !ok {
			t.Fatalf("admin manifest missing %s", svc)
		}
	}
	if manifest["device_id"] != grant["device_id"] {
		t.Fatal("manifest device_id mismatch")
	}

	// A stranger authenticated by the IdP but unknown to vault: fail closed.
	stranger := e.idp.mint(t, "sub-stranger", "stranger@example.com", "x")
	if code, _ := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": stranger}); code != 403 {
		t.Fatal("stranger register not refused")
	}

	// Invite flow: admin pre-creates by email; first login binds.
	ctx := context.Background()
	maya, err := e.store.Write().CreateUser(ctx, "maya", "maya@example.com", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.store.Write().SetGrant(ctx, maya.ID, "torrent", []string{"read", "write"}); err != nil {
		t.Fatal(err)
	}
	mayaToken := e.idp.mint(t, "sub-maya", "maya@example.com", "maya")
	code, mayaGrant := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": mayaToken, "device_name": "maya-phone", "platform": "ios"})
	if code != 200 {
		t.Fatalf("invite register = %d %v", code, mayaGrant)
	}

	// Member manifest: exactly the granted service.
	code, m2 := e.call(t, "GET", "/v1/manifest", mayaGrant["access_token"].(string), nil)
	if code != 200 {
		t.Fatalf("member manifest = %d", code)
	}
	mcaps := m2["capabilities"].(map[string]any)
	if len(mcaps) != 1 || mcaps["torrent"] == nil {
		t.Fatalf("member caps = %v", mcaps)
	}

	// An UNVERIFIED email must NOT bind a pending invite: create a fresh
	// invite, then present a token with email_verified:false for it → refused.
	if _, err := e.store.Write().CreateUser(ctx, "eve", "eve@example.com", "", "member", "", ""); err != nil {
		t.Fatal(err)
	}
	unverified := e.idp.mintUnverified(t, "sub-eve", "eve@example.com", "eve")
	if code, _ := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": unverified}); code != 403 {
		t.Fatalf("unverified-email invite bind not refused (got %d)", code)
	}
}

func TestRefreshRotationAndGrace(t *testing.T) {
	e := newTestEnv(t)
	tok := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")
	_, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok})
	refresh0 := grant["refresh_token"].(string)

	// Normal rotation.
	code, g1 := e.call(t, "POST", "/v1/token", "", map[string]any{"refresh_token": refresh0})
	if code != 200 {
		t.Fatalf("refresh = %d", code)
	}
	refresh1 := g1["refresh_token"].(string)
	if refresh1 == refresh0 {
		t.Fatal("refresh token not rotated")
	}

	// Replaying the OLD token within the grace window still works (flaky
	// network double-refresh) and does NOT revoke the device.
	code, g2 := e.call(t, "POST", "/v1/token", "", map[string]any{"refresh_token": refresh0})
	if code != 200 {
		t.Fatalf("grace replay = %d, want 200", code)
	}

	// The newest tokens keep working.
	code, _ = e.call(t, "GET", "/v1/manifest", g2["access_token"].(string), nil)
	if code != 200 {
		t.Fatalf("access after grace replay = %d", code)
	}

	// Age the rotation beyond the grace window, then replay the stale token:
	// theft signal — device revoked, everything dies.
	stale := time.Now().Add(-2 * auth.RotationGrace)
	if _, err := e.store.Read().DB().Exec(
		`UPDATE devices SET rotated_at = ?`, stale.Unix()); err != nil {
		t.Fatal(err)
	}
	code, _ = e.call(t, "POST", "/v1/token", "", map[string]any{"refresh_token": refresh0})
	if code != 401 {
		t.Fatalf("stale replay = %d, want 401", code)
	}
	// Device gone: even the latest refresh token is dead now.
	code, _ = e.call(t, "POST", "/v1/token", "", map[string]any{
		"refresh_token": g2["refresh_token"].(string)})
	if code != 401 {
		t.Fatalf("post-revocation refresh = %d, want 401", code)
	}
}

var _ = fmt.Sprintf // keep fmt for future debugging
