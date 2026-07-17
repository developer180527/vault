package store

import (
	"context"
	"errors"
	"testing"
)

func seedUser(t *testing.T, s *Store, username string) string {
	t.Helper()
	u, err := s.Write().CreateUser(context.Background(), username,
		username+"@example.com", "", "member", "https://idp", "sub-"+username)
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	return u.ID
}

func seedCatalogTrack(t *testing.T, s *Store, rel, title, artist string) string {
	t.Helper()
	ctx := context.Background()
	err := s.Write().UpsertCatalogTrack(ctx, CatalogTrack{
		RelPath: rel, Size: 100, Mtime: 1000,
		Title: title, Artist: artist, Album: "Album",
	})
	if err != nil {
		t.Fatalf("upsert %s: %v", rel, err)
	}
	existing, err := s.Read().ExistingCatalogTracks(ctx)
	if err != nil {
		t.Fatalf("existing: %v", err)
	}
	return existing[rel].ID
}

func TestUpsertCatalogTrack_AdminEditsSurviveRescan(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	id := seedCatalogTrack(t, s, "a/song.mp3", "Raw Tag Title", "Raw Artist")

	// Admin normalizes the metadata.
	if err := s.Write().UpdateCatalogMeta(ctx, id, CatalogTrack{
		Title: "Clean Title", Artist: "Clean Artist", Album: "Clean Album",
		Genre: "Rock", TrackNo: 3, Year: 2001,
	}); err != nil {
		t.Fatalf("update meta: %v", err)
	}

	// A rescan sees the file changed (new size/mtime) and re-upserts with
	// tag-derived metadata — the admin's edits must win.
	if err := s.Write().UpsertCatalogTrack(ctx, CatalogTrack{
		RelPath: "a/song.mp3", Size: 200, Mtime: 2000,
		Title: "Raw Tag Title", Artist: "Raw Artist", HasArt: true,
	}); err != nil {
		t.Fatalf("rescan upsert: %v", err)
	}

	got, err := s.Read().CatalogTrackByID(ctx, id)
	if err != nil {
		t.Fatalf("by id: %v", err)
	}
	if got.Title != "Clean Title" || got.Artist != "Clean Artist" || got.Year != 2001 {
		t.Fatalf("admin edits lost on rescan: %+v", got)
	}
	if got.Size != 200 || !got.HasArt {
		t.Fatalf("file facts not refreshed: %+v", got)
	}
	// And the UUID is stable across the rescan.
	existing, _ := s.Read().ExistingCatalogTracks(ctx)
	if existing["a/song.mp3"].ID != id {
		t.Fatalf("track id changed across rescan")
	}
}

func TestSearchCatalog_FTSReflectsAdminEdits(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	id := seedCatalogTrack(t, s, "b/track.m4a", "Obscure Name", "Someone")

	if hits, _ := s.Read().SearchCatalog(ctx, "obsc", 10); len(hits) != 1 {
		t.Fatalf("prefix search hits = %d, want 1", len(hits))
	}

	// After an admin rename the FTS triggers must keep the index in sync.
	if err := s.Write().UpdateCatalogMeta(ctx, id, CatalogTrack{
		Title: "Bohemian Rhapsody", Artist: "Queen",
	}); err != nil {
		t.Fatalf("update meta: %v", err)
	}
	if hits, _ := s.Read().SearchCatalog(ctx, "queen", 10); len(hits) != 1 {
		t.Fatalf("post-edit search hits != 1")
	}
	if hits, _ := s.Read().SearchCatalog(ctx, "obscure", 10); len(hits) != 0 {
		t.Fatalf("stale FTS row survived the edit")
	}
}

func TestPlaylists_OwnershipAndOrdering(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	venu := seedUser(t, s, "venu")
	maya := seedUser(t, s, "maya")
	t1 := seedCatalogTrack(t, s, "one.mp3", "One", "A")
	t2 := seedCatalogTrack(t, s, "two.mp3", "Two", "B")

	p, err := s.Write().CreatePlaylist(ctx, venu, "Focus")
	if err != nil {
		t.Fatalf("create playlist: %v", err)
	}

	// Append order is preserved; re-adding is idempotent.
	for _, id := range []string{t2, t1, t2} {
		if err := s.Write().AddToPlaylist(ctx, venu, p.ID, id); err != nil {
			t.Fatalf("add %s: %v", id, err)
		}
	}
	got, err := s.Read().PlaylistTracks(ctx, venu, p.ID)
	if err != nil {
		t.Fatalf("playlist tracks: %v", err)
	}
	if len(got) != 2 || got[0].ID != t2 || got[1].ID != t1 {
		t.Fatalf("order wrong: %+v", got)
	}

	// No cross-user access: maya can't read, add to, or delete venu's list.
	if _, err := s.Read().PlaylistTracks(ctx, maya, p.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-user read err = %v, want ErrNotFound", err)
	}
	if err := s.Write().AddToPlaylist(ctx, maya, p.ID, t1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-user add err = %v, want ErrNotFound", err)
	}
	if err := s.Write().DeletePlaylist(ctx, maya, p.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-user delete err = %v, want ErrNotFound", err)
	}

	// Remove + count via listing.
	if err := s.Write().RemoveFromPlaylist(ctx, venu, p.ID, t2); err != nil {
		t.Fatalf("remove: %v", err)
	}
	lists, err := s.Read().PlaylistsForUser(ctx, venu)
	if err != nil {
		t.Fatalf("playlists for user: %v", err)
	}
	if len(lists) != 1 || lists[0].TrackCount != 1 {
		t.Fatalf("lists = %+v", lists)
	}

	// Deleting a catalog track cascades out of playlists.
	if err := s.Write().DeleteCatalogTracks(ctx, []string{t1}); err != nil {
		t.Fatalf("delete track: %v", err)
	}
	got, _ = s.Read().PlaylistTracks(ctx, venu, p.ID)
	if len(got) != 0 {
		t.Fatalf("cascade failed: %+v", got)
	}
}

func TestInsertListen(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	venu := seedUser(t, s, "venu")
	tr := seedCatalogTrack(t, s, "x.mp3", "X", "Y")

	if err := s.Write().InsertListen(ctx, venu, tr, 30000, "library"); err != nil {
		t.Fatalf("insert listen: %v", err)
	}
	// Unknown track fails closed (FK) — the event log stays clean for ML.
	if err := s.Write().InsertListen(ctx, venu, "not-a-track", 0, "search"); err == nil {
		t.Fatalf("listen with bogus track id succeeded")
	}
}
