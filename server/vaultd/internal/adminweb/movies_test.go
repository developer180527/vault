package adminweb

import (
	"bytes"
	"context"
	"net/url"
	"strings"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/store"
)

func TestMovieCatalogEditAndAudit(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Seed a title directly (scan needs ffmpeg; the store is what the admin
	// pages read/write).
	if err := e.store.Write().UpsertMovie(context.Background(), store.CatalogMovie{
		RelPath: "Dune (2021).mkv", Size: 1, Mtime: 1, Kind: "movie",
		Title: "Dune", Year: 2021, DurationMs: 9000000, Height: 2160,
		VCodec: "hevc", Container: "mkv",
	}, `{"audio":[{"index":0,"lang":"eng","default":true},{"index":1,"lang":"fra","title":"French"}],"subs":[{"index":0,"lang":"eng","text":true}]}`); err != nil {
		t.Fatal(err)
	}

	// List page shows the title + its track counts.
	page := e.doGet(t, session, "/movies")
	body := page.Body.String()
	if page.Code != 200 || !strings.Contains(body, "Dune") ||
		!strings.Contains(body, "2&nbsp;audio") {
		t.Fatalf("movies list = %d, missing title/tracks", page.Code)
	}

	movies, _ := e.store.Read().Movies(context.Background())
	id := movies[0].ID

	// Edit page renders the stream summary (French audio, English sub).
	page = e.doGet(t, session, "/movies/"+id)
	if !strings.Contains(page.Body.String(), "French") {
		t.Fatal("edit page missing audio track detail")
	}

	// Save new metadata → persists and audits.
	form := url.Values{
		"title": {"Dune: Part One"}, "year": {"2021"},
		"kind": {"movie"}, "overview": {"Paul goes to Arrakis."},
	}
	rec := e.doPost(t, session, "/movies/"+id,
		"application/x-www-form-urlencoded", bytes.NewBufferString(form.Encode()))
	if rec.Code != 303 {
		t.Fatalf("save = %d, want 303", rec.Code)
	}
	got, _ := e.store.Read().MovieByID(context.Background(), id)
	if got.Title != "Dune: Part One" || got.Overview != "Paul goes to Arrakis." {
		t.Fatalf("edit not saved: %+v", got)
	}

	// Audited.
	entries, _ := e.store.Read().ListAudit(context.Background(), 10)
	if len(entries) == 0 || entries[0].Action != "movie.edit" {
		t.Fatalf("audit = %v", entries)
	}

	// Delete requires the exact title typed.
	bad := url.Values{"confirm": {"wrong"}}
	e.doPost(t, session, "/movies/"+id+"/delete",
		"application/x-www-form-urlencoded", bytes.NewBufferString(bad.Encode()))
	if _, err := e.store.Read().MovieByID(context.Background(), id); err != nil {
		t.Fatal("title deleted despite wrong confirmation")
	}
	good := url.Values{"confirm": {"Dune: Part One"}}
	e.doPost(t, session, "/movies/"+id+"/delete",
		"application/x-www-form-urlencoded", bytes.NewBufferString(good.Encode()))
	if _, err := e.store.Read().MovieByID(context.Background(), id); err == nil {
		t.Fatal("title survived confirmed delete")
	}
}
