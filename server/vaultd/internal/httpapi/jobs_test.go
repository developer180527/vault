package httpapi

import (
	"bufio"
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/developer180527/vault/vaultd/internal/auth"
	"github.com/developer180527/vault/vaultd/internal/jobs"
	"github.com/developer180527/vault/vaultd/internal/library"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// instantRunner completes immediately with a staged file, so the HTTP path
// (submit → schedule → deliver → SSE) is exercised without real qBit/yt-dlp.
type instantRunner struct{ staging string }

func (r instantRunner) Run(ctx context.Context, job store.Job, report func(float64, string)) (string, error) {
	report(0.5, "working")
	p := filepath.Join(r.staging, "out-"+job.ID)
	return p, os.WriteFile(p, []byte("x"), 0o600)
}

func TestJobsHTTPFlow(t *testing.T) {
	idp := newFakeIDP(t)
	dataRoot := t.TempDir()
	staging := filepath.Join(dataRoot, "staging")
	if err := os.MkdirAll(staging, 0o770); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "v.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })

	engine := jobs.New(slog.New(slog.DiscardHandler), st, dataRoot, 2,
		map[string]jobs.Runner{store.JobKindDownload: instantRunner{staging}})
	engine.Start()
	t.Cleanup(engine.Stop)

	verifier, _ := auth.NewOIDCVerifier(context.Background(), idp.issuer, "vault-app")
	h := New(Options{
		Log: slog.New(slog.DiscardHandler), Store: st, Verifier: verifier,
		SetupCode: "cafe1234", DataRoot: dataRoot, Jobs: engine,
	})
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)

	// Bootstrap admin (admin implicitly holds torrent:write).
	e := &testEnv{handler: h, store: st, idp: idp, dataRoot: dataRoot}
	tok := idp.mint(t, "sub-admin", "venu@example.com", "venu")
	_, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok, "device_name": "mbp", "platform": "macos"})
	access := grant["access_token"].(string)

	// A member WITHOUT torrent:write is forbidden from submitting.
	maya, _ := st.Write().CreateUser(context.Background(), "maya", "maya@example.com", "", "member", "", "")
	_ = library.Ensure(dataRoot, "maya")
	mayaTok := idp.mint(t, "sub-maya", "maya@example.com", "maya")
	_, mg := e.call(t, "POST", "/v1/devices/register", "", map[string]any{"id_token": mayaTok})
	code, _ := e.call(t, "POST", "/v1/jobs", mg["access_token"].(string),
		map[string]any{"source": "https://x.test/a"})
	if code != 403 {
		t.Fatalf("member without grant submit = %d, want 403", code)
	}
	_ = maya

	// Admin opens the SSE stream against the real server.
	req, _ := http.NewRequest("GET", srv.URL+"/v1/jobs/watch", nil)
	req.Header.Set("Authorization", "Bearer "+access)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		t.Fatalf("watch status %d", res.StatusCode)
	}

	// Submit a job.
	code, submitted := e.call(t, "POST", "/v1/jobs", access,
		map[string]any{"source": "https://x.test/clip.mp4"})
	if code != 200 {
		t.Fatalf("submit = %d %v", code, submitted)
	}
	jobID := submitted["id"].(string)
	if submitted["title"] != "clip.mp4" {
		t.Fatalf("title = %v, want clip.mp4", submitted["title"])
	}

	// Read the SSE stream until the job shows completed.
	sc := bufio.NewScanner(res.Body)
	deadline := time.Now().Add(5 * time.Second)
	sawCompleted := false
	for time.Now().Before(deadline) && sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "data:") &&
			strings.Contains(line, jobID) &&
			strings.Contains(line, `"state":"completed"`) {
			sawCompleted = true
			break
		}
	}
	if !sawCompleted {
		t.Fatal("job never reported completed on SSE stream")
	}

	// Delivered into the admin's downloads/.
	entries, _ := os.ReadDir(filepath.Join(dataRoot, "users", "venu", "downloads"))
	if len(entries) != 1 {
		t.Fatalf("expected 1 delivered file, got %d", len(entries))
	}
}
