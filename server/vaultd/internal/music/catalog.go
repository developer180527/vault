package music

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// CatalogRoot is where the shared, admin-curated music lives. Only the admin
// (via disk or a future upload UI) writes here; members only ever reference
// tracks by UUID — there is no client-path surface into the catalog at all.
func (s *Service) CatalogRoot() string {
	return filepath.Join(s.DataRoot, "catalog", "music")
}

// EnsureCatalog creates the catalog directory (idempotent; called at boot).
func (s *Service) EnsureCatalog() error {
	return os.MkdirAll(s.CatalogRoot(), 0o750)
}

// CatalogTrackPath resolves a catalog track to its absolute file path.
func (s *Service) CatalogTrackPath(t *store.CatalogTrack) string {
	return filepath.Join(s.CatalogRoot(), filepath.FromSlash(t.RelPath))
}

// ScanCatalog walks catalog/music, tag-parses new/changed files (size+mtime
// key) and prunes vanished rows — the same incremental pattern as the
// per-user zone scan. Admin-triggered (vaultdctl / endpoint) rather than
// per-listing: the catalog only changes when the admin loads music, and
// listings must stay a pure DB read at any library size.
//
// Rescans deliberately do NOT overwrite title/artist/album/genre: the store
// upsert only refreshes file facts, so admin metadata edits survive.
func (s *Service) ScanCatalog(ctx context.Context) (added, pruned int, err error) {
	if err := s.EnsureCatalog(); err != nil {
		return 0, 0, err
	}
	existing, err := s.Store.Read().ExistingCatalogTracks(ctx)
	if err != nil {
		return 0, 0, err
	}
	seen := map[string]bool{}
	root := s.CatalogRoot()

	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if !audioExt[strings.ToLower(filepath.Ext(path))] {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		info, err := d.Info()
		if err != nil {
			return nil
		}
		seen[rel] = true
		if k, ok := existing[rel]; ok &&
			k.Size == info.Size() && k.Mtime == info.ModTime().Unix() {
			return nil // unchanged
		}
		t := s.readTags(path)
		ct := store.CatalogTrack{
			RelPath: rel,
			Size:    info.Size(),
			Mtime:   info.ModTime().Unix(),
			Title:   t.Title,
			Artist:  t.Artist,
			Album:   t.Album,
			Genre:   t.Genre,
			TrackNo: t.TrackNo,
			Year:    t.Year,
			HasArt:  t.HasArt,
		}
		if err := s.Store.Write().UpsertCatalogTrack(ctx, ct); err != nil {
			s.Log.Warn("catalog upsert failed", "rel", rel, "err", err)
			return nil
		}
		added++
		return nil
	})
	if err != nil {
		return added, 0, err
	}

	var gone []string
	for rel, k := range existing {
		if !seen[rel] {
			gone = append(gone, k.ID)
		}
	}
	if len(gone) > 0 {
		if err := s.Store.Write().DeleteCatalogTracks(ctx, gone); err != nil {
			return added, 0, err
		}
	}
	s.Log.Info("catalog scan complete",
		"changed", added, "pruned", len(gone))
	return added, len(gone), nil
}

// CatalogArtwork extracts embedded art from a catalog track, lazily per
// request (ETag-cached at the HTTP layer, like per-user artwork).
func (s *Service) CatalogArtwork(t *store.CatalogTrack) ([]byte, string, bool) {
	return artworkFromFile(s.CatalogTrackPath(t))
}
