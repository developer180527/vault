package adminweb

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// post drives an authed same-origin form POST.
func (e *env) post(t *testing.T, session *http.Cookie, path string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("POST", path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Sec-Fetch-Site", "same-origin")
	req.AddCookie(session)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec
}

func (e *env) get(t *testing.T, session *http.Cookie, path string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("GET", path, nil)
	req.AddCookie(session)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec
}

func TestUsersPageAndInvite(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Invite a member…
	rec := e.post(t, session, "/users", url.Values{
		"username": {"maya"}, "email": {"maya@example.com"},
	})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("invite = %d", rec.Code)
	}
	// …and the list shows both, with maya pending.
	rec = e.get(t, session, "/users")
	body := rec.Body.String()
	if rec.Code != 200 || !strings.Contains(body, "maya") ||
		!strings.Contains(body, "invited") {
		t.Fatalf("users list = %d, maya/invited missing", rec.Code)
	}

	// Bad invite bounces with a flash, creates nothing.
	rec = e.post(t, session, "/users", url.Values{
		"username": {"x"}, "email": {"not-an-email"},
	})
	if rec.Code != http.StatusSeeOther ||
		!strings.Contains(rec.Header().Get("Location"), "msg=") {
		t.Fatalf("bad invite = %d", rec.Code)
	}
}

func TestGrantMatrixRoundTrip(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	maya := e.seedUser(t, "maya", "member", "sub-maya")
	session := e.login(t)

	// Grant music read+stream and files read via the form encoding.
	rec := e.post(t, session, "/users/"+maya.ID+"/grants", url.Values{
		"grant/music/read":   {"on"},
		"grant/music/stream": {"on"},
		"grant/files/read":   {"on"},
	})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("save grants = %d", rec.Code)
	}
	grants, err := e.store.Read().GrantsForUser(context.Background(), maya.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(grants["music"]) != 2 || len(grants["files"]) != 1 {
		t.Fatalf("grants = %v", grants)
	}

	// The detail page reflects them as checked boxes (attribute order/spacing
	// is template-formatting; just look right after the input's name).
	body := e.get(t, session, "/users/"+maya.ID).Body.String()
	_, after, found := strings.Cut(body, `name="grant/music/read"`)
	if !found || !strings.Contains(after[:60], "checked") {
		t.Fatalf("matrix not pre-checked for music/read")
	}
	_, after, found = strings.Cut(body, `name="grant/music/write"`)
	if !found || strings.Contains(after[:60], "checked") {
		t.Fatalf("music/write should NOT be pre-checked")
	}

	// Unchecking everything removes the rows entirely.
	rec = e.post(t, session, "/users/"+maya.ID+"/grants", url.Values{})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("clear grants = %d", rec.Code)
	}
	grants, _ = e.store.Read().GrantsForUser(context.Background(), maya.ID)
	if len(grants) != 0 {
		t.Fatalf("grants not cleared: %v", grants)
	}
}

func TestBlastRadiusGuards(t *testing.T) {
	e := newEnv(t)
	admin := e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Can't disable yourself.
	rec := e.post(t, session, "/users/"+admin.ID+"/status",
		url.Values{"status": {"disabled"}})
	loc := rec.Header().Get("Location")
	if !strings.Contains(loc, "your+own") && !strings.Contains(loc, "your%20own") {
		t.Fatalf("self-disable not refused: %q", loc)
	}
	u, _ := e.store.Read().UserByID(context.Background(), admin.ID)
	if u.Status != "active" {
		t.Fatalf("self-disable went through")
	}

	// Can't change your own role.
	rec = e.post(t, session, "/users/"+admin.ID+"/role",
		url.Values{"role": {"member"}})
	u, _ = e.store.Read().UserByID(context.Background(), admin.ID)
	if u.Role != "admin" {
		t.Fatalf("self-demotion went through")
	}

	// Last-admin protection: a SECOND admin demoting the only other one is
	// fine, but demoting the LAST active admin is refused.
	other := e.seedUser(t, "kai", "admin", "sub-kai")
	// venu demotes kai — allowed (venu remains).
	rec = e.post(t, session, "/users/"+other.ID+"/role",
		url.Values{"role": {"member"}})
	u, _ = e.store.Read().UserByID(context.Background(), other.ID)
	if u.Role != "member" {
		t.Fatalf("legit demotion refused")
	}
	// kai (member now) can't be the excuse: venu is the last active admin,
	// and self-guard already blocks; verify CountActiveAdmins backs it.
	if n, _ := e.store.Read().CountActiveAdmins(context.Background()); n != 1 {
		t.Fatalf("active admins = %d, want 1", n)
	}
}

func TestCatalogEditAndTypedConfirmDelete(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Seed a catalog file + scan through the panel.
	root := filepath.Join(e.music.DataRoot, "catalog", "music")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "song.mp3"),
		[]byte("bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := e.post(t, session, "/catalog/scan", nil)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("scan = %d", rec.Code)
	}

	// The catalog page lists it (filename-fallback title).
	body := e.get(t, session, "/catalog").Body.String()
	if !strings.Contains(body, "song") {
		t.Fatalf("catalog list missing track")
	}
	tracks, _ := e.store.Read().CatalogTracks(context.Background())
	if len(tracks) != 1 {
		t.Fatalf("tracks = %d", len(tracks))
	}
	id := tracks[0].ID

	// Edit metadata through the form.
	rec = e.post(t, session, "/catalog/"+id, url.Values{
		"title": {"Real Title"}, "artist": {"Real Artist"},
		"album": {"Album"}, "year": {"1999"},
	})
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("edit = %d", rec.Code)
	}
	got, _ := e.store.Read().CatalogTrackByID(context.Background(), id)
	if got.Title != "Real Title" || got.Year != 1999 {
		t.Fatalf("edit not applied: %+v", got)
	}

	// Delete with the WRONG confirmation → refused, row intact.
	rec = e.post(t, session, "/catalog/"+id+"/delete",
		url.Values{"confirm": {"wrong"}})
	if _, err := e.store.Read().CatalogTrackByID(context.Background(), id); err != nil {
		t.Fatalf("track deleted despite wrong confirmation")
	}

	// Exact-title confirmation → row gone, file in .trash, not on disk.
	rec = e.post(t, session, "/catalog/"+id+"/delete",
		url.Values{"confirm": {"Real Title"}})
	if rec.Code != http.StatusSeeOther {
		body, _ := io.ReadAll(rec.Result().Body)
		t.Fatalf("delete = %d %s", rec.Code, body)
	}
	if _, err := e.store.Read().CatalogTrackByID(context.Background(), id); err == nil {
		t.Fatalf("row survived delete")
	}
	if _, err := os.Stat(filepath.Join(root, "song.mp3")); !os.IsNotExist(err) {
		t.Fatalf("file still in catalog")
	}
	if _, err := os.Stat(filepath.Join(root, ".trash", "song.mp3")); err != nil {
		t.Fatalf("file not in .trash: %v", err)
	}

	// A rescan does NOT resurrect the trashed file.
	_ = e.post(t, session, "/catalog/scan", nil)
	if tracks, _ := e.store.Read().CatalogTracks(context.Background()); len(tracks) != 0 {
		t.Fatalf("trashed file re-indexed: %v", tracks)
	}
}
