package httpapi

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// seedSong drops a (tag-less) audio file into the admin's music zone; the
// indexer's filename-fallback must still list and stream it.
func (e *testEnv) seedSong(t *testing.T, rel string, contents string) {
	t.Helper()
	path := filepath.Join(e.dataRoot, "users", "venu", "music", filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestMusicListSearchStream(t *testing.T) {
	e := newTestEnv(t)
	tok := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")
	_, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok})
	access := grant["access_token"].(string)

	e.seedSong(t, "Daft Punk - Around the World.mp3", "mp3bytes-around")
	e.seedSong(t, "albums/Discovery/One More Time.flac", "flacbytes-onemore")
	e.seedSong(t, "notes.txt", "not audio") // must be ignored

	// Listing scans incrementally and returns both tracks, not the .txt.
	code, body := e.call(t, "GET", "/v1/music/tracks", access, nil)
	if code != 200 {
		t.Fatalf("tracks = %d %v", code, body)
	}
	tracks := body["tracks"].([]any)
	if len(tracks) != 2 {
		t.Fatalf("tracks = %d, want 2 (%v)", len(tracks), tracks)
	}
	byTitle := map[string]map[string]any{}
	for _, raw := range tracks {
		tr := raw.(map[string]any)
		byTitle[tr["title"].(string)] = tr
	}
	if byTitle["Daft Punk - Around the World"] == nil ||
		byTitle["One More Time"] == nil {
		t.Fatalf("filename-fallback titles missing: %v", byTitle)
	}

	// FTS search: prefix match finds the flac; nonsense finds nothing.
	code, body = e.call(t, "GET", "/v1/music/search?q=more+tim", access, nil)
	if code != 200 || len(body["tracks"].([]any)) != 1 {
		t.Fatalf("search = %d %v", code, body)
	}
	_, body = e.call(t, "GET", "/v1/music/search?q=zzznothing", access, nil)
	if len(body["tracks"].([]any)) != 0 {
		t.Fatalf("nonsense search hit: %v", body)
	}

	// Stream honors Range (seek) and returns the actual bytes.
	id := byTitle["One More Time"]["id"].(string)
	req := httptest.NewRequest("GET", "/v1/music/tracks/"+id+"/stream", nil)
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Range", "bytes=4-8")
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 206 || rec.Body.String() != "bytes" {
		t.Fatalf("range stream = %d %q", rec.Code, rec.Body.String())
	}

	// No embedded artwork in a tag-less file → 404.
	code, _ = e.call(t, "GET", "/v1/music/tracks/"+id+"/art", access, nil)
	if code != 404 {
		t.Fatalf("art = %d, want 404", code)
	}

	// Deleting the file prunes it from the next listing (and from search).
	if err := os.Remove(filepath.Join(e.dataRoot,
		"users", "venu", "music", "albums", "Discovery", "One More Time.flac")); err != nil {
		t.Fatal(err)
	}
	_, body = e.call(t, "GET", "/v1/music/tracks", access, nil)
	if n := len(body["tracks"].([]any)); n != 1 {
		t.Fatalf("tracks after delete = %d, want 1", n)
	}
	_, body = e.call(t, "GET", "/v1/music/search?q=more", access, nil)
	if n := len(body["tracks"].([]any)); n != 0 {
		t.Fatalf("search after delete = %d, want 0", n)
	}

	// A member WITHOUT the music grant is refused (fail closed).
	stranger := mintMemberWithoutMusic(t, e)
	code, _ = e.call(t, "GET", "/v1/music/tracks", stranger, nil)
	if code != 403 {
		t.Fatalf("ungranted member tracks = %d, want 403", code)
	}
}

// mintMemberWithoutMusic invites + registers a member holding only files:read.
func mintMemberWithoutMusic(t *testing.T, e *testEnv) string {
	t.Helper()
	ctx := t.Context()
	u, err := e.store.Write().CreateUser(ctx, "maya", "maya@example.com", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.store.Write().SetGrant(ctx, u.ID, "files", []string{"read"}); err != nil {
		t.Fatal(err)
	}
	tok := e.idp.mint(t, "sub-maya", "maya@example.com", "maya")
	code, grant := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": tok, "device_name": "maya-phone", "platform": "ios"})
	if code != 200 {
		t.Fatalf("register = %d %v", code, grant)
	}
	return grant["access_token"].(string)
}
