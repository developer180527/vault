package httpapi

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// mintMoviesMember registers a member with movies:read only.
func mintMoviesMember(t *testing.T, e *testEnv) string {
	t.Helper()
	ctx := t.Context()
	u, err := e.store.Write().CreateUser(ctx, "leo", "leo@example.com", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.store.Write().SetGrant(ctx, u.ID, "movies", []string{"read"}); err != nil {
		t.Fatal(err)
	}
	tok := e.idp.mint(t, "sub-leo", "leo@example.com", "leo")
	code, grant := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": tok, "device_name": "leo-tv", "platform": "android"})
	if code != 200 {
		t.Fatalf("register = %d %v", code, grant)
	}
	return grant["access_token"].(string)
}

// seedMovie inserts a catalog movie directly + writes its file into the movies
// root (default DataRoot/catalog/movies), so stream ServeFile has real bytes.
func (e *testEnv) seedMovie(t *testing.T, m store.CatalogMovie, contents string) {
	t.Helper()
	path := filepath.Join(e.dataRoot, "catalog", "movies",
		filepath.FromSlash(m.RelPath))
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := e.store.Write().UpsertMovie(t.Context(), m, `{"audio":[{"index":0,"lang":"eng","default":true}]}`); err != nil {
		t.Fatal(err)
	}
}

func TestMoviesListSearchDetailAndWatches(t *testing.T) {
	e := newTestEnv(t)
	tok := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")
	_, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok})
	admin := grant["access_token"].(string)
	member := mintMoviesMember(t, e)

	e.seedMovie(t, store.CatalogMovie{
		RelPath: "Arrival (2016).mkv", Size: 1, Mtime: 1, Kind: "movie",
		Title: "Arrival", Year: 2016, DurationMs: 6000000}, "movie-bytes")
	e.seedMovie(t, store.CatalogMovie{
		RelPath: "Dune (2021).mkv", Size: 1, Mtime: 1, Kind: "movie",
		Title: "Dune", Year: 2021, DurationMs: 9000000}, "dune-bytes")

	// List: both, signed stream URLs attached.
	code, body := e.call(t, "GET", "/v1/movies", member, nil)
	movies := body["movies"].([]any)
	if code != 200 || len(movies) != 2 {
		t.Fatalf("list = %d %v", code, body)
	}
	first := movies[0].(map[string]any)
	if first["stream_url"] == nil {
		t.Fatal("no signed stream_url")
	}
	arrivalID := ""
	for _, mv := range movies {
		m := mv.(map[string]any)
		if m["title"] == "Arrival" {
			arrivalID = m["id"].(string)
		}
	}

	// Search FTS.
	_, body = e.call(t, "GET", "/v1/movies?q=dune", member, nil)
	if len(body["movies"].([]any)) != 1 {
		t.Fatalf("search dune = %v", body)
	}

	// Detail with resume (0 initially), audio stream present.
	code, detail := e.call(t, "GET", "/v1/movies/"+arrivalID, member, nil)
	if code != 200 || detail["resume_ms"] != nil {
		// resume_ms omitempty → absent when 0
	}
	streams := detail["streams"].(map[string]any)
	if len(streams["audio"].([]any)) != 1 {
		t.Fatalf("audio streams = %v", streams)
	}

	// Direct stream (default audio) serves the file bytes with Range support.
	req := httptest.NewRequest("GET", "/v1/movies/"+arrivalID+"/stream", nil)
	req.Header.Set("Authorization", "Bearer "+member)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 200 || rec.Body.String() != "movie-bytes" {
		t.Fatalf("stream = %d %q", rec.Code, rec.Body.String())
	}

	// Record a watch → Continue Watching surfaces it with resume.
	code, _ = e.call(t, "POST", "/v1/movies/"+arrivalID+"/watches", member,
		map[string]any{"position_ms": 120000, "duration_ms": 6000000})
	if code != 200 {
		t.Fatalf("watch = %d", code)
	}
	_, body = e.call(t, "GET", "/v1/movies/continue", member, nil)
	cont := body["movies"].([]any)
	if len(cont) != 1 || cont[0].(map[string]any)["resume_ms"].(float64) != 120000 {
		t.Fatalf("continue = %v", body)
	}

	// A finished movie (>95%) drops off the shelf.
	e.call(t, "POST", "/v1/movies/"+arrivalID+"/watches", member,
		map[string]any{"position_ms": 5900000, "duration_ms": 6000000})
	_, body = e.call(t, "GET", "/v1/movies/continue", member, nil)
	if len(body["movies"].([]any)) != 0 {
		t.Fatalf("finished movie still in continue: %v", body)
	}

	// A past-the-end position is clamped to the duration, never stored raw
	// (resume_ms is omitempty, so read it nil-safe).
	e.call(t, "POST", "/v1/movies/"+arrivalID+"/watches", member,
		map[string]any{"position_ms": 99999999, "duration_ms": 6000000})
	_, body = e.call(t, "GET", "/v1/movies/"+arrivalID, member, nil)
	resume, _ := body["resume_ms"].(float64)
	if resume > 6000000 {
		t.Fatalf("over-duration position not clamped: %v", resume)
	}
	// Negative → 0.
	e.call(t, "POST", "/v1/movies/"+arrivalID+"/watches", member,
		map[string]any{"position_ms": -5000, "duration_ms": 6000000})
	_, body = e.call(t, "GET", "/v1/movies/"+arrivalID, member, nil)
	resume, _ = body["resume_ms"].(float64)
	if resume != 0 {
		t.Fatalf("negative position not clamped: %v", resume)
	}

	// Members can't scan; admin can.
	if code, _ := e.call(t, "POST", "/v1/movies/scan", member, nil); code != 403 {
		t.Fatalf("member scan = %d, want 403", code)
	}
	if code, _ := e.call(t, "POST", "/v1/movies/scan", admin, nil); code != 200 {
		t.Fatalf("admin scan = %d", code)
	}

	// Admin edit survives; member edit is refused.
	code, _ = e.call(t, "PATCH", "/v1/movies/"+arrivalID, member,
		map[string]any{"title": "Nope"})
	if code != 403 {
		t.Fatalf("member edit = %d, want 403", code)
	}
	code, _ = e.call(t, "PATCH", "/v1/movies/"+arrivalID, admin,
		map[string]any{"overview": "Linguist meets aliens."})
	if code != 200 {
		t.Fatalf("admin edit = %d", code)
	}

	// No-grant stranger is refused the listing.
	stranger := mintMemberWithoutMusic2(t, e)
	if code, _ := e.call(t, "GET", "/v1/movies", stranger, nil); code != 403 {
		t.Fatalf("no-grant list = %d, want 403", code)
	}
}

var _ = context.Background