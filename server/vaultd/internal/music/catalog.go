package music

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
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
		if err != nil {
			return nil
		}
		if d.IsDir() {
			// Dot-dirs are service-internal (.trash holds admin-deleted
			// tracks) — never re-index them.
			if path != root && strings.HasPrefix(d.Name(), ".") {
				return fs.SkipDir
			}
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

// CatalogArtwork returns a track's cover: the admin-uploaded override when
// present, else art embedded in the file's tags. Lazy per request, ETag'd at
// the HTTP layer via [CatalogArtVersion].
func (s *Service) CatalogArtwork(t *store.CatalogTrack) ([]byte, string, bool) {
	if data, err := os.ReadFile(s.artOverridePath(t.ID)); err == nil && len(data) > 0 {
		return data, http.DetectContentType(data), true
	}
	return artworkFromFile(s.CatalogTrackPath(t))
}

// ErrNotAudio rejects uploads whose extension isn't a known audio container.
var ErrNotAudio = errors.New("not an audio file")

// sanitizeFilename keeps a HUMAN track name (spaces, unicode, case) and only
// strips what's hostile in a filename: path separators, control chars, and
// the usual reserved punctuation. Usernames have their own, far stricter
// sanitizer — using it here mangled titles ("My Song" → "mysong").
func sanitizeFilename(raw string) string {
	out := make([]rune, 0, len(raw))
	for _, r := range raw {
		switch {
		case r < 0x20, r == 0x7f:
		case strings.ContainsRune("/\\:*?\"<>|", r):
		default:
			out = append(out, r)
		}
	}
	s := strings.Trim(strings.TrimSpace(string(out)), ".")
	if s == "" {
		return "track"
	}
	return s
}

// SaveUpload writes uploaded bytes into the catalog under a sanitized
// filename, atomically (.part + rename), never escaping CatalogRoot. Returns
// the final base name. The caller scans afterward to index it — SaveUpload
// only lands the file. A name collision gets a " (2)", " (3)"… suffix so an
// upload never silently overwrites existing music.
func (s *Service) SaveUpload(filename string, data []byte) (string, error) {
	ext := strings.ToLower(filepath.Ext(filename))
	if !audioExt[ext] {
		return "", ErrNotAudio
	}
	base := sanitizeFilename(
		strings.TrimSuffix(filepath.Base(filename), filepath.Ext(filename)))
	if err := s.EnsureCatalog(); err != nil {
		return "", err
	}
	name := base + ext
	dst := filepath.Join(s.CatalogRoot(), name)
	for i := 2; ; i++ {
		if _, err := os.Stat(dst); os.IsNotExist(err) {
			break
		}
		name = fmt.Sprintf("%s (%d)%s", base, i, ext)
		dst = filepath.Join(s.CatalogRoot(), name)
	}
	tmp := dst + ".part"
	if err := os.WriteFile(tmp, data, 0o640); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	return name, nil
}

// artOverridePath is where an admin-uploaded cover for [id] lives — a
// dot-dir sidecar (never scanned), keyed by the track's stable UUID so it
// survives file renames and rescans.
func (s *Service) artOverridePath(id string) string {
	return filepath.Join(s.CatalogRoot(), ".art", filepath.Base(id)+".img")
}

// SetCatalogArtOverride stores admin-uploaded cover art for a track. The
// override wins over embedded tag art everywhere (panel AND member API).
func (s *Service) SetCatalogArtOverride(id string, data []byte) error {
	p := s.artOverridePath(id)
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o640)
}

// CatalogArtVersion feeds art ETags: the override's mtime when present
// (uploading new art must bust caches), else the audio file's mtime.
func (s *Service) CatalogArtVersion(t *store.CatalogTrack) int64 {
	if fi, err := os.Stat(s.artOverridePath(t.ID)); err == nil {
		return fi.ModTime().Unix()
	}
	return t.Mtime
}

// TrashCatalogTrack removes a track: the FILE moves into the catalog's
// `.trash/` (never hard-deleted — MUSIC.md; the scan skips dot-dirs so it
// won't be re-indexed), then the row is deleted, which cascades the track out
// of playlists. A missing file is fine — the row still goes.
func (s *Service) TrashCatalogTrack(ctx context.Context, t *store.CatalogTrack) error {
	src := s.CatalogTrackPath(t)
	dst := filepath.Join(s.CatalogRoot(), ".trash", filepath.FromSlash(t.RelPath))
	if _, err := os.Stat(src); err == nil {
		if err := os.MkdirAll(filepath.Dir(dst), 0o770); err != nil {
			return err
		}
		if err := os.Rename(src, dst); err != nil {
			return err
		}
	}
	return s.Store.Write().DeleteCatalogTracks(ctx, []string{t.ID})
}
