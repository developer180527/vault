package adminweb

import (
	"bytes"
	"context"
	"net/url"
	"strings"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/store"
)

func TestTagHelpers(t *testing.T) {
	if got := splitTags("Asha Bhosle, Mohammed Rafi"); len(got) != 2 ||
		got[0] != "Asha Bhosle" || got[1] != "Mohammed Rafi" {
		t.Fatalf("split = %q", got)
	}
	// Blanks and stray commas don't become empty tags.
	if got := splitTags(" , A ,, "); len(got) != 1 || got[0] != "A" {
		t.Fatalf("split blanks = %q", got)
	}
	// Pasting the old comma format in one go still tokenizes.
	if got := addTag([]string{"A"}, "B, C"); len(got) != 3 {
		t.Fatalf("paste-add = %q", got)
	}
	// Case-insensitive dedupe, order preserved.
	if got := addTag([]string{"Kishore Kumar"}, "kishore kumar"); len(got) != 1 {
		t.Fatalf("dupe not ignored: %q", got)
	}
	if got := removeTag([]string{"A", "B"}, "a"); len(got) != 1 || got[0] != "B" {
		t.Fatalf("remove = %q", got)
	}
	if joinTags([]string{"A", "B"}) != "A, B" {
		t.Fatal("join must stay comma+space — the CLIENT splits on it")
	}
}

// The whole point: adding and removing artists one at a time, and never
// mangling them into a single blob.
func TestTrackTagEditing(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)
	ctx := context.Background()

	if err := e.store.Write().UpsertCatalogTrack(ctx, store.CatalogTrack{
		RelPath: "song.mp3", Size: 1, Mtime: 1, Title: "Abhi Na Jao",
	}); err != nil {
		t.Fatal(err)
	}
	tracks, _ := e.store.Read().CatalogTracks(ctx)
	id := tracks[0].ID
	post := func(form url.Values) {
		t.Helper()
		form.Set("title", "Abhi Na Jao")
		e.doPost(t, session, "/catalog/"+id,
			"application/x-www-form-urlencoded",
			bytes.NewBufferString(form.Encode()))
	}

	// Add one artist (what pressing Enter sends).
	post(url.Values{"add_artist": {"Asha Bhosle"}})
	got, _ := e.store.Read().CatalogTrackByID(ctx, id)
	if got.Artist != "Asha Bhosle" {
		t.Fatalf("after first add: %q", got.Artist)
	}

	// Add a second: existing chips ride along as repeated hidden inputs.
	post(url.Values{"artist": {"Asha Bhosle"}, "add_artist": {"Mohammed Rafi"}})
	got, _ = e.store.Read().CatalogTrackByID(ctx, id)
	if got.Artist != "Asha Bhosle, Mohammed Rafi" {
		t.Fatalf("after second add: %q", got.Artist)
	}

	// A duplicate is ignored rather than doubling the credit.
	post(url.Values{
		"artist": {"Asha Bhosle", "Mohammed Rafi"}, "add_artist": {"asha bhosle"}})
	got, _ = e.store.Read().CatalogTrackByID(ctx, id)
	if got.Artist != "Asha Bhosle, Mohammed Rafi" {
		t.Fatalf("dupe added: %q", got.Artist)
	}

	// Remove one (clicking a chip's ×).
	post(url.Values{
		"artist":        {"Asha Bhosle", "Mohammed Rafi"},
		"remove_artist": {"Asha Bhosle"}})
	got, _ = e.store.Read().CatalogTrackByID(ctx, id)
	if got.Artist != "Mohammed Rafi" {
		t.Fatalf("after remove: %q", got.Artist)
	}

	// A plain Save (no add/remove) leaves the chips exactly as they were —
	// this is what would break if the hidden inputs weren't round-tripped.
	post(url.Values{"artist": {"Mohammed Rafi"}, "genre": {"Bollywood"}})
	got, _ = e.store.Read().CatalogTrackByID(ctx, id)
	if got.Artist != "Mohammed Rafi" || got.Genre != "Bollywood" {
		t.Fatalf("plain save lost tags: artist=%q genre=%q",
			got.Artist, got.Genre)
	}

	// The edit page renders chips + the add box, and focuses the field just
	// touched so the next value can be typed straight away.
	page := e.doGet(t, session, "/catalog/"+id+"?focus=artist")
	html := page.Body.String()
	for _, want := range []string{
		`name="remove_artist" value="Mohammed Rafi"`, // chip × button
		`name="artist" value="Mohammed Rafi"`,        // round-trip hidden input
		`name="add_artist"`,                          // the add box
		"autofocus",                                  // cursor lands there
		"implicit-submit",                            // Enter can't fire a ×
	} {
		if !strings.Contains(html, want) {
			t.Fatalf("edit page missing %q", want)
		}
	}
}
