package httpapi

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// seedCatalogSong drops a (tag-less) audio file into the shared catalog area.
func (e *testEnv) seedCatalogSong(t *testing.T, rel, contents string) {
	t.Helper()
	path := filepath.Join(e.dataRoot, "catalog", "music", filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

// mintMusicMember invites + registers a member with music:read ONLY —
// the normal listener: can browse/stream/playlist, cannot mutate the catalog.
func mintMusicMember(t *testing.T, e *testEnv) string {
	return mintMusicMemberNamed(t, e, "maya", "sub-maya")
}

// mintMusicMemberNamed is mintMusicMember with an explicit identity, so a test
// can stand up two distinct music members (e.g. to prove per-user isolation).
func mintMusicMemberNamed(t *testing.T, e *testEnv, username, sub string) string {
	t.Helper()
	ctx := t.Context()
	email := username + "@example.com"
	u, err := e.store.Write().CreateUser(ctx, username, email, "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.store.Write().SetGrant(ctx, u.ID, "music", []string{"read"}); err != nil {
		t.Fatal(err)
	}
	tok := e.idp.mint(t, sub, email, username)
	code, grant := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": tok, "device_name": username + "-phone", "platform": "ios"})
	if code != 200 {
		t.Fatalf("register = %d %v", code, grant)
	}
	return grant["access_token"].(string)
}

func TestCatalogScanListStreamAndAdminEdit(t *testing.T) {
	e := newTestEnv(t)
	tok := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")
	_, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok})
	admin := grant["access_token"].(string)
	member := mintMusicMember(t, e)

	e.seedCatalogSong(t, "queen/Bohemian Rhapsody.mp3", "flacbytes-bohemian")
	e.seedCatalogSong(t, "readme.txt", "not audio")

	// The catalog listing is a pure DB read: empty until the admin scans.
	code, body := e.call(t, "GET", "/v1/music/catalog", member, nil)
	if code != 200 || len(body["tracks"].([]any)) != 0 {
		t.Fatalf("pre-scan catalog = %d %v", code, body)
	}

	// Members cannot scan; the admin can.
	code, _ = e.call(t, "POST", "/v1/music/catalog/scan", member, nil)
	if code != 403 {
		t.Fatalf("member scan = %d, want 403", code)
	}
	code, body = e.call(t, "POST", "/v1/music/catalog/scan", admin, nil)
	if code != 200 || body["changed"].(float64) != 1 {
		t.Fatalf("admin scan = %d %v", code, body)
	}

	// Every music:read member sees the shared catalog now.
	_, body = e.call(t, "GET", "/v1/music/catalog", member, nil)
	tracks := body["tracks"].([]any)
	if len(tracks) != 1 {
		t.Fatalf("catalog = %v", tracks)
	}
	tr := tracks[0].(map[string]any)
	id := tr["id"].(string)
	if tr["title"].(string) != "Bohemian Rhapsody" { // filename fallback
		t.Fatalf("title = %v", tr["title"])
	}

	// Member streams with Range.
	req := httptest.NewRequest("GET", "/v1/music/catalog/"+id+"/stream", nil)
	req.Header.Set("Authorization", "Bearer "+member)
	req.Header.Set("Range", "bytes=4-8")
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 206 || rec.Body.String() != "bytes" {
		t.Fatalf("range stream = %d %q", rec.Code, rec.Body.String())
	}

	// Metadata edit: member 403, admin 200; partial patch keeps the title.
	code, _ = e.call(t, "PATCH", "/v1/music/catalog/"+id, member,
		map[string]any{"artist": "Queen"})
	if code != 403 {
		t.Fatalf("member edit = %d, want 403", code)
	}
	code, body = e.call(t, "PATCH", "/v1/music/catalog/"+id, admin,
		map[string]any{"artist": "Queen", "album": "A Night at the Opera", "year": 1975})
	if code != 200 || body["artist"].(string) != "Queen" ||
		body["title"].(string) != "Bohemian Rhapsody" {
		t.Fatalf("admin edit = %d %v", code, body)
	}

	// Search reflects the edit (FTS triggers), and edits survive a rescan.
	_, body = e.call(t, "GET", "/v1/music/catalog?q=queen", member, nil)
	if len(body["tracks"].([]any)) != 1 {
		t.Fatalf("search after edit: %v", body)
	}
	e.call(t, "POST", "/v1/music/catalog/scan", admin, nil)
	_, body = e.call(t, "GET", "/v1/music/catalog?q=queen", member, nil)
	if len(body["tracks"].([]any)) != 1 {
		t.Fatalf("admin edit lost after rescan: %v", body)
	}

	// music:read is still required at all (fail closed).
	stranger := mintMemberWithoutMusic2(t, e)
	code, _ = e.call(t, "GET", "/v1/music/catalog", stranger, nil)
	if code != 403 {
		t.Fatalf("ungranted catalog = %d, want 403", code)
	}
}

func TestCatalogPlaylistsAndListens(t *testing.T) {
	e := newTestEnv(t)
	tok := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")
	_, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok})
	admin := grant["access_token"].(string)
	member := mintMusicMember(t, e)

	e.seedCatalogSong(t, "song-a.mp3", "aaaa")
	e.seedCatalogSong(t, "song-b.mp3", "bbbb")
	e.call(t, "POST", "/v1/music/catalog/scan", admin, nil)
	_, body := e.call(t, "GET", "/v1/music/catalog", member, nil)
	tracks := body["tracks"].([]any)
	idA := tracks[0].(map[string]any)["id"].(string)
	idB := tracks[1].(map[string]any)["id"].(string)

	// Create a playlist, add both tracks, list them back in order.
	code, pl := e.call(t, "POST", "/v1/music/playlists", member,
		map[string]any{"name": "Focus"})
	if code != 201 {
		t.Fatalf("create playlist = %d %v", code, pl)
	}
	plID := pl["id"].(string)
	for _, id := range []string{idB, idA} {
		code, _ = e.call(t, "POST", "/v1/music/playlists/"+plID+"/tracks", member,
			map[string]any{"track_id": id})
		if code != 200 {
			t.Fatalf("add %s = %d", id, code)
		}
	}
	// Bogus track ids are rejected — playlists can't hold dangling refs.
	code, _ = e.call(t, "POST", "/v1/music/playlists/"+plID+"/tracks", member,
		map[string]any{"track_id": "not-a-track"})
	if code != 404 {
		t.Fatalf("bogus track add = %d, want 404", code)
	}

	_, body = e.call(t, "GET", "/v1/music/playlists/"+plID+"/tracks", member, nil)
	got := body["tracks"].([]any)
	if len(got) != 2 || got[0].(map[string]any)["id"] != idB {
		t.Fatalf("playlist order: %v", got)
	}

	// Playlists are private: the admin cannot see or touch maya's list.
	code, _ = e.call(t, "GET", "/v1/music/playlists/"+plID+"/tracks", admin, nil)
	if code != 404 {
		t.Fatalf("cross-user playlist read = %d, want 404", code)
	}
	_, body = e.call(t, "GET", "/v1/music/playlists", admin, nil)
	if len(body["playlists"].([]any)) != 0 {
		t.Fatalf("admin sees maya's playlists: %v", body)
	}

	// Remove one, then the count on listing reflects it.
	code, _ = e.call(t, "DELETE", "/v1/music/playlists/"+plID+"/tracks/"+idB, member, nil)
	if code != 200 {
		t.Fatalf("remove = %d", code)
	}
	_, body = e.call(t, "GET", "/v1/music/playlists", member, nil)
	lists := body["playlists"].([]any)
	if len(lists) != 1 || lists[0].(map[string]any)["track_count"].(float64) != 1 {
		t.Fatalf("playlists = %v", lists)
	}

	// Listen events: valid one lands, bogus track id is a 400.
	code, _ = e.call(t, "POST", "/v1/music/listens", member,
		map[string]any{"track_id": idA, "source": "playlist:" + plID, "ms_played": 30000})
	if code != 201 {
		t.Fatalf("listen = %d", code)
	}
	code, _ = e.call(t, "POST", "/v1/music/listens", member,
		map[string]any{"track_id": "ghost"})
	if code != 400 {
		t.Fatalf("ghost listen = %d, want 400", code)
	}

	// Delete the playlist.
	code, _ = e.call(t, "DELETE", "/v1/music/playlists/"+plID, member, nil)
	if code != 200 {
		t.Fatalf("delete playlist = %d", code)
	}
	_, body = e.call(t, "GET", "/v1/music/playlists", member, nil)
	if len(body["playlists"].([]any)) != 0 {
		t.Fatalf("playlist survived delete: %v", body)
	}
}

// TestFavoritesAndMostPlayed covers per-user liked songs and the "You" shelf:
// likes are personal (idempotent, unlike removes cleanly, reject dangling ids)
// and most-played ranks by total ms_played.
func TestFavoritesAndMostPlayed(t *testing.T) {
	e := newTestEnv(t)
	tok := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")
	_, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok})
	admin := grant["access_token"].(string)
	member := mintMusicMember(t, e)

	e.seedCatalogSong(t, "song-a.mp3", "aaaa")
	e.seedCatalogSong(t, "song-b.mp3", "bbbb")
	e.call(t, "POST", "/v1/music/catalog/scan", admin, nil)
	_, body := e.call(t, "GET", "/v1/music/catalog", member, nil)
	tracks := body["tracks"].([]any)
	idA := tracks[0].(map[string]any)["id"].(string)
	idB := tracks[1].(map[string]any)["id"].(string)

	// Favorites start empty.
	_, body = e.call(t, "GET", "/v1/music/favorites", member, nil)
	if len(body["tracks"].([]any)) != 0 {
		t.Fatalf("favorites not empty at start: %v", body)
	}

	// Like B then A; re-liking A is idempotent (still one row each).
	for _, id := range []string{idB, idA, idA} {
		code, _ := e.call(t, "PUT", "/v1/music/favorites/"+id, member, nil)
		if code != 200 {
			t.Fatalf("like %s = %d", id, code)
		}
	}
	// Liking a track that doesn't exist is a 404.
	if code, _ := e.call(t, "PUT", "/v1/music/favorites/ghost", member, nil); code != 404 {
		t.Fatalf("like ghost = %d, want 404", code)
	}

	// Newest-liked-first: A was liked last, so it leads.
	_, body = e.call(t, "GET", "/v1/music/favorites", member, nil)
	favs := body["tracks"].([]any)
	if len(favs) != 2 || favs[0].(map[string]any)["id"] != idA {
		t.Fatalf("favorites order = %v", favs)
	}

	// Unlike A → only B remains.
	if code, _ := e.call(t, "DELETE", "/v1/music/favorites/"+idA, member, nil); code != 200 {
		t.Fatalf("unlike = %d", code)
	}
	_, body = e.call(t, "GET", "/v1/music/favorites", member, nil)
	favs = body["tracks"].([]any)
	if len(favs) != 1 || favs[0].(map[string]any)["id"] != idB {
		t.Fatalf("favorites after unlike = %v", favs)
	}

	// Most-played: no history yet → empty.
	_, body = e.call(t, "GET", "/v1/music/you/most-played", member, nil)
	if len(body["tracks"].([]any)) != 0 {
		t.Fatalf("most-played not empty before listens: %v", body)
	}
	// B gets more play time than A → B ranks first.
	e.call(t, "POST", "/v1/music/listens", member,
		map[string]any{"track_id": idA, "source": "library", "ms_played": 5000})
	e.call(t, "POST", "/v1/music/listens", member,
		map[string]any{"track_id": idB, "source": "library", "ms_played": 90000})
	_, body = e.call(t, "GET", "/v1/music/you/most-played", member, nil)
	top := body["tracks"].([]any)
	if len(top) != 2 || top[0].(map[string]any)["id"] != idB {
		t.Fatalf("most-played order = %v", top)
	}

	// Favorites are per-user: a second member sees none of the first's likes.
	other := mintMusicMemberNamed(t, e, "kai", "sub-kai")
	_, body = e.call(t, "GET", "/v1/music/favorites", other, nil)
	if len(body["tracks"].([]any)) != 0 {
		t.Fatalf("favorites leaked across users: %v", body)
	}
}

// mintMemberWithoutMusic2 mirrors music_test.go's helper with a distinct
// username so both tests can run in one env lifetime if ever merged.
func mintMemberWithoutMusic2(t *testing.T, e *testEnv) string {
	t.Helper()
	ctx := t.Context()
	u, err := e.store.Write().CreateUser(ctx, "noah", "noah@example.com", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.store.Write().SetGrant(ctx, u.ID, "files", []string{"read"}); err != nil {
		t.Fatal(err)
	}
	tok := e.idp.mint(t, "sub-noah", "noah@example.com", "noah")
	code, grant := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": tok, "device_name": "noah-phone", "platform": "ios"})
	if code != 200 {
		t.Fatalf("register = %d %v", code, grant)
	}
	return grant["access_token"].(string)
}
