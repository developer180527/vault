package adminweb

import (
	"context"
	"strings"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/store"
)

func TestInsightsPageAggregatesListens(t *testing.T) {
	e := newEnv(t)
	e.seedUser(t, "venu", "admin", "sub-venu")
	session := e.login(t)

	// Empty state first.
	page := e.doGet(t, session, "/insights")
	if page.Code != 200 || !strings.Contains(page.Body.String(), "Nothing to show yet") {
		t.Fatalf("empty insights = %d", page.Code)
	}

	// Seed one catalog track + listens from two users.
	ctx := context.Background()
	if err := e.store.Write().UpsertCatalogTrack(ctx, store.CatalogTrack{
		RelPath: "song.mp3", Size: 4, Mtime: 1,
		Title: "Yeh Shaam Mastani", Artist: "Kishore Kumar",
	}); err != nil {
		t.Fatal(err)
	}
	tracks, _ := e.store.Read().CatalogTracks(ctx)
	id := tracks[0].ID
	venu, _ := e.store.Read().UserByUsername(ctx, "venu")
	maya, _ := e.store.Write().CreateUser(ctx, "maya", "maya@example.com", "", "member", "", "")
	for range 3 {
		_ = e.store.Write().InsertListen(ctx, venu.ID, id, 60000, "library")
	}
	_ = e.store.Write().InsertListen(ctx, maya.ID, id, 30000, "search")

	// One backed-up original → the Photo backup section aggregates it.
	if _, err := e.store.Write().InsertPhoto(ctx, venu.ID, store.Photo{
		RelPath: "2025/07/IMG_1.jpg", Hash: "h1", Size: 2 << 20,
		Mime: "image/jpeg", Kind: "photo", TakenAt: 1752000000,
	}); err != nil {
		t.Fatal(err)
	}

	page = e.doGet(t, session, "/insights")
	html := page.Body.String()
	for _, want := range []string{
		"Yeh Shaam Mastani", "Kishore Kumar", // top track with artist
		"Most active listeners", "venu", "maya", // both listeners ranked
		"Recent listens", "search", // feed with source tag
		"Photo backup", "Per member", // photo analytics section
		"Library by capture year", "2025",
	} {
		if !strings.Contains(html, want) {
			t.Fatalf("insights missing %q", want)
		}
	}
}
