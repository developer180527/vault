// Package music indexes and serves a user's music/ library zone: an
// incremental tag scan into the store's tracks table (+FTS5), lazy artwork
// extraction, and path resolution for streaming. Design: docs/MUSIC.md.
package music

import (
	"context"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/dhowden/tag"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// Audio extensions the indexer picks up — keep in lockstep with the client's
// local-music scanner.
var audioExt = map[string]bool{
	".mp3": true, ".m4a": true, ".aac": true, ".flac": true, ".wav": true,
	".ogg": true, ".opus": true, ".aiff": true, ".alac": true,
}

// Service scans and resolves one-user music zones.
type Service struct {
	DataRoot   string
	Store      *store.Store
	Log        *slog.Logger
	FFmpegPath string // ffmpeg for the +faststart optimize pass ("" → PATH)

	warm *warmCache // hottest catalog tracks kept in RAM (nil = disabled)
}

// zone returns the absolute path of a user's music zone.
func (s *Service) zone(username string) string {
	return filepath.Join(s.DataRoot, "users", username, "music")
}

// TrackPath resolves an indexed track to its absolute file path.
func (s *Service) TrackPath(username string, t *store.Track) string {
	return filepath.Join(s.zone(username), filepath.FromSlash(t.RelPath))
}

// Scan walks the zone, tag-parses new/changed files (size+mtime key), and
// prunes rows whose files vanished. Cheap when nothing changed: a stat-walk.
// Runs on every listing, so the index never goes stale (docs/MUSIC.md).
func (s *Service) Scan(ctx context.Context, userID, username string) error {
	existing, err := s.Store.Read().ExistingTracks(ctx, userID)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	root := s.zone(username)

	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil // unreadable entries are skipped, not fatal
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
			return nil // unchanged — no tag parse
		}
		t := s.readTags(path)
		t.RelPath = rel
		t.Size = info.Size()
		t.Mtime = info.ModTime().Unix()
		if err := s.Store.Write().UpsertTrack(ctx, userID, t); err != nil {
			s.Log.Warn("track upsert failed", "rel", rel, "err", err)
		}
		return nil
	})
	if err != nil {
		return err
	}

	// Prune rows for files that no longer exist.
	var gone []string
	for rel, k := range existing {
		if !seen[rel] {
			gone = append(gone, k.ID)
		}
	}
	if len(gone) > 0 {
		if err := s.Store.Write().DeleteTracks(ctx, gone); err != nil {
			return err
		}
	}
	return nil
}

// readTags parses metadata, falling back to filename-as-title for tag-less
// files (they must still be listed and playable).
func (s *Service) readTags(path string) store.Track {
	name := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	t := store.Track{Title: name}

	f, err := os.Open(path)
	if err != nil {
		return t
	}
	defer f.Close()
	m, err := tag.ReadFrom(f)
	if err != nil {
		return t // unreadable/absent tags — filename fallback stands
	}
	if v := strings.TrimSpace(m.Title()); v != "" {
		t.Title = v
	}
	t.Artist = strings.TrimSpace(m.Artist())
	t.Album = strings.TrimSpace(m.Album())
	t.Genre = strings.TrimSpace(m.Genre())
	t.TrackNo, _ = m.Track()
	t.Year = m.Year()
	t.HasArt = m.Picture() != nil
	return t
}

// Artwork extracts the embedded picture (bytes + mime), parsed lazily per
// request — artwork is never duplicated into the DB; HTTP caching (ETag)
// makes repeat fetches free.
func (s *Service) Artwork(username string, t *store.Track) ([]byte, string, bool) {
	return artworkFromFile(s.TrackPath(username, t))
}

// artworkFromFile is the shared extraction used by both the per-user zone
// and the shared catalog.
func artworkFromFile(path string) ([]byte, string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, "", false
	}
	defer f.Close()
	m, err := tag.ReadFrom(f)
	if err != nil || m.Picture() == nil {
		return nil, "", false
	}
	p := m.Picture()
	mime := p.MIMEType
	if mime == "" {
		mime = "image/jpeg"
	}
	return p.Data, mime, true
}
