package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/jobs"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// fakeQbit stands in for qBittorrent: it serves a fixed torrent list and
// records which mutating calls actually reached it. That recording is the
// point — the isolation tests below assert that a forbidden request never
// arrives here at all, rather than merely that the caller saw an error.
type fakeQbit struct {
	mu       sync.Mutex
	torrents []jobs.Torrent
	calls    []string // "path hashes"
}

func (f *fakeQbit) server(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v2/auth/login", func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "SID", Value: "test-sid"})
		_, _ = w.Write([]byte("Ok."))
	})
	mux.HandleFunc("/api/v2/torrents/info", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		cat, hashes := r.FormValue("category"), r.FormValue("hashes")
		f.mu.Lock()
		defer f.mu.Unlock()
		out := []jobs.Torrent{}
		for _, tr := range f.torrents {
			if cat != "" && tr.Category != cat {
				continue
			}
			if hashes != "" && !strings.EqualFold(hashes, tr.Hash) {
				continue
			}
			out = append(out, tr)
		}
		_ = json.NewEncoder(w).Encode(out)
	})
	record := func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		f.mu.Lock()
		f.calls = append(f.calls, r.URL.Path+" "+r.FormValue("hashes"))
		f.mu.Unlock()
		_, _ = w.Write([]byte("Ok."))
	}
	for _, p := range []string{
		"/api/v2/torrents/stop", "/api/v2/torrents/pause",
		"/api/v2/torrents/start", "/api/v2/torrents/resume",
		"/api/v2/torrents/recheck", "/api/v2/torrents/delete",
		"/api/v2/torrents/add",
		"/api/v2/transfer/setDownloadLimit", "/api/v2/transfer/setUploadLimit",
	} {
		mux.HandleFunc(p, record)
	}
	mux.HandleFunc("/api/v2/transfer/info", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"dl_info_speed":100,"up_info_speed":50,
			"dl_rate_limit":0,"up_rate_limit":0,"use_alt_speed_limits":false}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func (f *fakeQbit) reached(path string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.calls {
		if strings.HasPrefix(c, path) {
			return true
		}
	}
	return false
}

// torrentEnv builds a server whose qBittorrent is the fake.
func torrentEnv(t *testing.T, fake *fakeQbit) *testEnv {
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
		t.Fatal(err)
	}
	dataRoot := t.TempDir()
	qsrv := fake.server(t)
	h := New(Options{
		Log: slog.New(slog.DiscardHandler), Store: st, Verifier: verifier,
		SetupCode: "cafe1234", DataRoot: dataRoot,
		Torrents:        jobs.NewQbitClient(qsrv.URL, "admin", "pw"),
		TorrentSavePath: filepath.Join(dataRoot, "staging", "torrents"),
	})
	return &testEnv{handler: h, store: st, idp: idp, dataRoot: dataRoot}
}

// mintTorrentMember registers a member with torrent read+write and returns
// (token, userID). The user id matters: it IS the qBittorrent category.
func mintTorrentMember(t *testing.T, e *testEnv, name string) (string, string) {
	t.Helper()
	ctx := t.Context()
	u, err := e.store.Write().CreateUser(ctx, name, name+"@x.test", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.store.Write().SetGrant(ctx, u.ID, "torrent", []string{"read", "write"}); err != nil {
		t.Fatal(err)
	}
	code, g := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": e.idp.mint(t, "sub-"+name, name+"@x.test", name)})
	if code != 200 {
		t.Fatalf("register %s = %d %v", name, code, g)
	}
	return g["access_token"].(string), u.ID
}

// THE security property: qBittorrent addresses torrents by hash and knows
// nothing about our users, so vaultd is the only thing keeping one member out
// of another's downloads.
func TestTorrentsAreIsolatedPerUser(t *testing.T) {
	fake := &fakeQbit{}
	e := torrentEnv(t, fake)
	_ = adminToken(t, e) // an admin must exist before members register
	alphaTok, alphaID := mintTorrentMember(t, e, "alpha")
	_, betaID := mintTorrentMember(t, e, "beta")

	const alphaHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const betaHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	fake.torrents = []jobs.Torrent{
		{Hash: alphaHash, Name: "alpha.iso", Category: alphaID, State: "downloading"},
		{Hash: betaHash, Name: "beta.iso", Category: betaID, State: "downloading"},
	}

	// The list is scoped: alpha sees only their own.
	code, body := e.call(t, "GET", "/v1/torrents", alphaTok, nil)
	if code != 200 {
		t.Fatalf("list = %d %v", code, body)
	}
	list, _ := body["torrents"].([]any)
	if len(list) != 1 {
		t.Fatalf("alpha sees %d torrents, want 1", len(list))
	}
	if got := list[0].(map[string]any)["name"]; got != "alpha.iso" {
		t.Fatalf("alpha sees %v, want alpha.iso", got)
	}

	// Acting on someone else's torrent is 404 — NOT 403, which would confirm
	// the hash exists and turn the endpoint into a probe.
	for _, path := range []string{
		"/v1/torrents/" + betaHash + "/pause",
		"/v1/torrents/" + betaHash + "/resume",
		"/v1/torrents/" + betaHash + "/recheck",
	} {
		if code, _ := e.call(t, "POST", path, alphaTok, nil); code != 404 {
			t.Fatalf("POST %s = %d, want 404", path, code)
		}
	}
	if code, _ := e.call(t, "DELETE", "/v1/torrents/"+betaHash, alphaTok, nil); code != 404 {
		t.Fatalf("delete other's torrent = %d, want 404", code)
	}

	// And crucially: no mutation ever reached qBittorrent.
	for _, p := range []string{
		"/api/v2/torrents/stop", "/api/v2/torrents/pause",
		"/api/v2/torrents/start", "/api/v2/torrents/resume",
		"/api/v2/torrents/recheck", "/api/v2/torrents/delete",
	} {
		if fake.reached(p) {
			t.Fatalf("a forbidden request reached qBittorrent: %s", p)
		}
	}

	// Alpha CAN act on their own.
	if code, _ := e.call(t, "POST", "/v1/torrents/"+alphaHash+"/pause", alphaTok, nil); code != 200 {
		t.Fatalf("pause own torrent = %d, want 200", code)
	}
	if !fake.reached("/api/v2/torrents/stop") && !fake.reached("/api/v2/torrents/pause") {
		t.Fatal("pausing own torrent never reached qBittorrent")
	}
}

// A hash from the URL is untrusted input; anything non-hex must be refused
// before it is ever interpolated into a qBittorrent call.
func TestTorrentHashIsValidated(t *testing.T) {
	fake := &fakeQbit{}
	e := torrentEnv(t, fake)
	_ = adminToken(t, e)
	tok, _ := mintTorrentMember(t, e, "alpha")

	for _, bad := range []string{"../../etc/passwd", "not-a-hash", "zzzz", "%20"} {
		code, _ := e.call(t, "POST", "/v1/torrents/"+bad+"/pause", tok, nil)
		if code != 404 && code != 400 {
			t.Fatalf("hash %q = %d, want 404/400", bad, code)
		}
	}
	if len(fake.calls) != 0 {
		t.Fatalf("a malformed hash reached qBittorrent: %v", fake.calls)
	}
}

// Global speed limits throttle the household's single pipe, so a member must
// not be able to set them even with torrent:write.
func TestSpeedLimitsAreAdminOnly(t *testing.T) {
	fake := &fakeQbit{}
	e := torrentEnv(t, fake)
	admin := adminToken(t, e)
	member, _ := mintTorrentMember(t, e, "alpha")

	if code, _ := e.call(t, "PUT", "/v1/torrents/limits", member,
		map[string]any{"dl_limit": 1000}); code != 403 {
		t.Fatalf("member set limits = %d, want 403", code)
	}
	if code, body := e.call(t, "PUT", "/v1/torrents/limits", admin,
		map[string]any{"dl_limit": 1000}); code != 200 {
		t.Fatalf("admin set limits = %d %v, want 200", code, body)
	}
	// A negative limit is nonsense and must be refused, not forwarded.
	if code, _ := e.call(t, "PUT", "/v1/torrents/limits", admin,
		map[string]any{"dl_limit": -5}); code != 400 {
		t.Fatalf("negative limit = %d, want 400", code)
	}
}

// Adding a .torrent must validate the file BEFORE qBittorrent sees it, so a
// bad upload fails with a clear reason instead of landing as a broken entry.
func TestAddTorrentFileRejectsGarbage(t *testing.T) {
	fake := &fakeQbit{}
	e := torrentEnv(t, fake)
	_ = adminToken(t, e)
	tok, _ := mintTorrentMember(t, e, "alpha")

	if code := e.putRawMethod(t, "POST", "/v1/torrents/file", tok,
		[]byte("definitely not bencode")); code != 415 {
		t.Fatalf("garbage .torrent = %d, want 415", code)
	}
	if fake.reached("/api/v2/torrents/add") {
		t.Fatal("an invalid .torrent was forwarded to qBittorrent")
	}
}
