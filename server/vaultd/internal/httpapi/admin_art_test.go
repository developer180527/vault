package httpapi

import (
	"bytes"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// pngBytes is a minimal valid PNG header — enough for http.DetectContentType
// to sniff "image/png", which is what the handler gates on.
var pngBytes = append(
	[]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A},
	bytes.Repeat([]byte{0}, 64)...,
)

// putRaw sends a raw (non-JSON) body — art upload takes image bytes directly.
func (e *testEnv) putRaw(t *testing.T, path, bearer string, body []byte) int {
	t.Helper()
	req := httptest.NewRequest("PUT", path, bytes.NewReader(body))
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec.Code
}

// adminToken bootstraps the first admin and returns its access token.
func adminToken(t *testing.T, e *testEnv) string {
	t.Helper()
	code, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": e.idp.mint(t, "a", "a@x.test", "admin"),
	})
	if code != 200 {
		t.Fatalf("setup = %d %v", code, grant)
	}
	return grant["access_token"].(string)
}

// firstCatalogTrackID scans the catalog and returns a track id.
func firstCatalogTrackID(t *testing.T, e *testEnv, admin string) string {
	t.Helper()
	if code, body := e.call(t, "POST", "/v1/music/catalog/scan", admin, nil); code != 200 {
		t.Fatalf("scan = %d %v", code, body)
	}
	code, body := e.call(t, "GET", "/v1/music/catalog", admin, nil)
	if code != 200 {
		t.Fatalf("catalog = %d %v", code, body)
	}
	tracks, _ := body["tracks"].([]any)
	if len(tracks) == 0 {
		t.Fatal("no catalog tracks after scan")
	}
	return tracks[0].(map[string]any)["id"].(string)
}

func TestAdminSetTrackArt(t *testing.T) {
	e := newTestEnv(t)
	admin := adminToken(t, e)
	e.seedCatalogSong(t, "Song.mp3", "audio-bytes")
	id := firstCatalogTrackID(t, e, admin)

	if code := e.putRaw(t, "/v1/admin/catalog/"+id+"/art", admin, pngBytes); code != 200 {
		t.Fatalf("put art = %d, want 200", code)
	}

	// The override lands beside the catalog, in the dot-dir the scanner skips.
	override := filepath.Join(e.dataRoot, "catalog", "music", ".art", id+".img")
	got, err := os.ReadFile(override)
	if err != nil {
		t.Fatalf("override not written: %v", err)
	}
	if !bytes.Equal(got, pngBytes) {
		t.Fatal("override content mismatch")
	}

	// has_art MUST flip: the client skips art fetches when it's false, so
	// without this the uploaded cover would never even be requested.
	_, body := e.call(t, "GET", "/v1/music/catalog", admin, nil)
	tracks, _ := body["tracks"].([]any)
	first := tracks[0].(map[string]any)
	if first["has_art"] != true {
		t.Fatalf("has_art = %v, want true", first["has_art"])
	}
	// art_version must be non-zero so clients can cache-bust the cover URL.
	if v, _ := first["art_version"].(float64); v == 0 {
		t.Fatal("art_version = 0, cover URLs would stay cached")
	}

	// And the art actually serves.
	if code, _ := e.call(t, "GET", "/v1/music/catalog/"+id+"/art", admin, nil); code != 200 {
		t.Fatalf("get art = %d, want 200", code)
	}
}

func TestAdminArtRejectsNonImageAndNonAdmin(t *testing.T) {
	e := newTestEnv(t)
	admin := adminToken(t, e)
	e.seedCatalogSong(t, "Song.mp3", "audio-bytes")
	id := firstCatalogTrackID(t, e, admin)

	// Content is sniffed, not trusted: a mislabelled upload is refused.
	if code := e.putRaw(t, "/v1/admin/catalog/"+id+"/art", admin,
		[]byte("this is definitely not an image")); code != 415 {
		t.Fatalf("non-image = %d, want 415", code)
	}
	if code := e.putRaw(t, "/v1/admin/catalog/"+id+"/art", admin, nil); code != 400 {
		t.Fatalf("empty body = %d, want 400", code)
	}

	// A member with music grants still can't curate — the role gate is the
	// real enforcement, independent of what the manifest advertises.
	member := mintMusicMember(t, e)
	if code := e.putRaw(t, "/v1/admin/catalog/"+id+"/art", member, pngBytes); code != 403 {
		t.Fatalf("member = %d, want 403", code)
	}
	if code := e.putRaw(t, "/v1/admin/catalog/"+id+"/art", "", pngBytes); code != 401 {
		t.Fatalf("anonymous = %d, want 401", code)
	}
}

func TestAdminUploadsRequireAdminRole(t *testing.T) {
	e := newTestEnv(t)
	_ = adminToken(t, e)
	member := mintMusicMember(t, e)

	code, _ := e.call(t, "POST", "/v1/admin/uploads", member, map[string]any{
		"kind": "music", "name": "x.mp3", "size": 10,
	})
	if code != 403 {
		t.Fatalf("member upload = %d, want 403", code)
	}
	if code, _ := e.call(t, "GET", "/v1/admin/uploads", member, nil); code != 403 {
		t.Fatalf("member list = %d, want 403", code)
	}
}
