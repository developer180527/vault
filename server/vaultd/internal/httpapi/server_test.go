package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// Opening the store runs migrations; the server answers health. This is the
// M2 skeleton's exit proof: the binary stands up end to end.
func TestHealthAndMigrations(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "vault.db")
	st, err := store.Open(context.Background(), dbPath)
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	defer st.Close()

	// Migrations created the users table.
	var n int
	if err := st.Read().DB().QueryRow(
		`SELECT COUNT(1) FROM sqlite_master WHERE type='table' AND name='users'`).Scan(&n); err != nil {
		t.Fatalf("query schema: %v", err)
	}
	if n != 1 {
		t.Fatalf("users table missing after migrate (got %d)", n)
	}

	h := New(Options{Log: slog.New(slog.DiscardHandler), Store: st})

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("healthz status = %d", rec.Code)
	}
	var body map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["status"] != "ok" {
		t.Fatalf("healthz body = %v", body)
	}
	if rec.Header().Get("X-Request-ID") == "" {
		t.Fatal("missing X-Request-ID header")
	}
}
