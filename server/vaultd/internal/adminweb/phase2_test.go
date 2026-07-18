package adminweb

import (
	"bytes"
	"context"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// doGet / doPost drive the panel as a signed-in same-origin browser.
func (e *env) doGet(t *testing.T, session *http.Cookie, path string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("GET", path, nil)
	req.AddCookie(session)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec
}

func (e *env) doPost(t *testing.T, session *http.Cookie, path, contentType string, body *bytes.Buffer) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("POST", path, body)
	req.AddCookie(session)
	req.Header.Set("Sec-Fetch-Site", "same-origin")
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec
}

// multipartBody builds a multipart form with the given file parts.
func multipartBody(t *testing.T, field string, files map[string][]byte) (*bytes.Buffer, string) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for name, data := range files {
		fw, err := mw.CreateFormFile(field, name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := fw.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := mw.Close(); err != nil {
		t.Fatal(err)
	}
	return &buf, mw.FormDataContentType()
}

func TestCatalogUploadIndexesAndAudits(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	body, ct := multipartBody(t, "files", map[string][]byte{
		"My Song.mp3": []byte("mp3-bytes-here"),
		"notes.txt":   []byte("not audio"),
	})
	rec := e.doPost(t, session, "/catalog/upload", ct, body)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("upload = %d, want 303", rec.Code)
	}
	loc := rec.Header().Get("Location")
	if !strings.Contains(loc, "Uploaded+1") || !strings.Contains(loc, "1+skipped") {
		t.Fatalf("flash = %q, want 1 uploaded / 1 skipped", loc)
	}

	// The scan indexed it → catalog page lists the (filename-fallback) title.
	page := e.doGet(t, session, "/catalog")
	if !strings.Contains(page.Body.String(), "My Song") {
		t.Fatal("uploaded track missing from catalog page")
	}

	// Audited.
	entries, err := e.store.Read().ListAudit(context.Background(), 10)
	if err != nil || len(entries) == 0 {
		t.Fatalf("audit: %v (%d entries)", err, len(entries))
	}
	if entries[0].Action != "catalog.upload" {
		t.Fatalf("audit action = %q", entries[0].Action)
	}
}

func TestArtworkOverrideUploadAndServe(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Seed one track via upload (tag-less file → HasArt=false).
	body, ct := multipartBody(t, "files",
		map[string][]byte{"Track.mp3": []byte("audio")})
	e.doPost(t, session, "/catalog/upload", ct, body)
	tracks, _ := e.store.Read().CatalogTracks(context.Background())
	if len(tracks) != 1 {
		t.Fatalf("tracks = %d, want 1", len(tracks))
	}
	id := tracks[0].ID

	// A tiny valid PNG header so DetectContentType says image/png.
	png := append([]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a},
		bytes.Repeat([]byte{0}, 64)...)
	body, ct = multipartBody(t, "art", map[string][]byte{"cover.png": png})
	rec := e.doPost(t, session, "/catalog/"+id+"/art", ct, body)
	if rec.Code != http.StatusSeeOther ||
		!strings.Contains(rec.Header().Get("Location"), "Artwork+updated") {
		t.Fatalf("art upload = %d %q", rec.Code, rec.Header().Get("Location"))
	}

	// Served back, override wins, has_art flipped.
	art := e.doGet(t, session, "/catalog/"+id+"/art")
	if art.Code != 200 || !bytes.Equal(art.Body.Bytes(), png) {
		t.Fatalf("art serve = %d (%d bytes)", art.Code, art.Body.Len())
	}
	if got := art.Header().Get("Content-Type"); got != "image/png" {
		t.Fatalf("art content-type = %q", got)
	}
	tr, _ := e.store.Read().CatalogTrackByID(context.Background(), id)
	if !tr.HasArt {
		t.Fatal("has_art not set after art upload")
	}

	// A text file is refused.
	body, ct = multipartBody(t, "art", map[string][]byte{"x.txt": []byte("hello plain text not an image at all")})
	rec = e.doPost(t, session, "/catalog/"+id+"/art", ct, body)
	if !strings.Contains(rec.Header().Get("Location"), "isn%27t+an+image") &&
		!strings.Contains(rec.Header().Get("Location"), "isn") {
		t.Fatalf("non-image accepted: %q", rec.Header().Get("Location"))
	}
}

func TestActivityFeedRendersAuditTrail(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Invite → one audit row.
	form := bytes.NewBufferString("username=maya&email=maya%40example.com")
	e.doPost(t, session, "/users", "application/x-www-form-urlencoded", form)

	page := e.doGet(t, session, "/activity")
	if page.Code != 200 {
		t.Fatalf("activity = %d", page.Code)
	}
	html := page.Body.String()
	if !strings.Contains(html, "user.invite") || !strings.Contains(html, "maya") {
		t.Fatal("invite not in activity feed")
	}
}

func TestSystemPageRenders(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Give the DB-size card something to find.
	dbDir := filepath.Join(e.music.DataRoot, "system", "db")
	_ = os.MkdirAll(dbDir, 0o750)
	_ = os.WriteFile(filepath.Join(dbDir, "vault.db"), []byte("x"), 0o640)

	page := e.doGet(t, session, "/system")
	if page.Code != 200 {
		t.Fatalf("system = %d", page.Code)
	}
	html := page.Body.String()
	for _, want := range []string{"Free on data volume", "Enrolled devices", "Catalog tracks"} {
		if !strings.Contains(html, want) {
			t.Fatalf("system page missing %q", want)
		}
	}
}
