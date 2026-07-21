// Package movies indexes and serves the shared movie/show catalog. It mirrors
// the music catalog service: incremental scan, DB-authoritative metadata,
// signed-URL streaming (handled in httpapi). What's new is multi-track media:
// ffprobe enumerates audio + subtitle streams at scan so the client can offer
// a language/subtitle picker, ffmpeg remuxes to switch the default audio track
// (zero re-encode), and extracts text subtitles to WebVTT on demand.
//
// Design: docs/MOVIES.md.
package movies

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// videoExt is what the scanner picks up.
var videoExt = map[string]bool{
	".mp4": true, ".mkv": true, ".m4v": true, ".mov": true, ".avi": true,
	".webm": true, ".wmv": true, ".flv": true, ".ts": true, ".m2ts": true,
}

// subExt are sidecar subtitle files matched to a video by basename.
var subExt = map[string]bool{
	".srt": true, ".vtt": true, ".ass": true, ".ssa": true, ".sub": true,
}

// textSubCodecs convert cleanly to WebVTT; image subs (pgs, dvdsub/vobsub)
// need OCR and are surfaced but marked non-text.
var textSubCodecs = map[string]bool{
	"subrip": true, "srt": true, "ass": true, "ssa": true, "webvtt": true,
	"mov_text": true, "text": true,
}

// Service scans and resolves the movie catalog.
type Service struct {
	Root       string // movies catalog dir (HDD pool in prod)
	Store      *store.Store
	Log        *slog.Logger
	Prober     Prober // ffprobe wrapper (injectable for tests)
	FFmpegPath string // for remux + subtitle extraction

	// MaxConcurrentTranscodes caps simultaneous real (re-encode) transcodes
	// so viewers can't peg every core. 0 → default 2. See stream.go.
	MaxConcurrentTranscodes int
	semOnce                 sync.Once
	sem                     chan struct{}
}

// EnsureRoot creates the catalog directory (idempotent; called at boot).
func (s *Service) EnsureRoot() error { return os.MkdirAll(s.Root, 0o750) }

// MoviePath resolves a catalog movie to its absolute file path.
func (s *Service) MoviePath(m *store.CatalogMovie) string {
	return filepath.Join(s.Root, filepath.FromSlash(m.RelPath))
}

// artOverridePath is an admin-uploaded poster (dot-dir sidecar, never scanned).
func (s *Service) artOverridePath(id string) string {
	return filepath.Join(s.Root, ".art", filepath.Base(id)+".img")
}

// Scan walks the catalog, ffprobes new/changed video files, records their
// audio/subtitle streams (plus sidecar subs), and prunes vanished rows. Same
// incremental (size,mtime) pattern as music; admin metadata survives.
func (s *Service) Scan(ctx context.Context) (added, pruned int, err error) {
	if err := s.EnsureRoot(); err != nil {
		return 0, 0, err
	}
	existing, err := s.Store.Read().ExistingMovies(ctx)
	if err != nil {
		return 0, 0, err
	}
	seen := map[string]bool{}
	root := s.Root

	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if path != root && strings.HasPrefix(d.Name(), ".") {
				return fs.SkipDir // .trash, .art
			}
			return nil
		}
		if !videoExt[strings.ToLower(filepath.Ext(path))] {
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
		if k, ok := existing[rel]; ok && k.Size == info.Size() &&
			k.Mtime == info.ModTime().Unix() {
			return nil // unchanged
		}

		m := s.probeToMovie(path, rel, info.Size(), info.ModTime().Unix())
		blob, _ := json.Marshal(m.Streams)
		if err := s.Store.Write().UpsertMovie(ctx, m, string(blob)); err != nil {
			s.Log.Warn("movie upsert failed", "rel", rel, "err", err)
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
		if err := s.Store.Write().DeleteMovies(ctx, gone); err != nil {
			return added, 0, err
		}
	}
	s.Log.Info("movie scan complete", "changed", added, "pruned", len(gone))
	return added, len(gone), nil
}

// probeToMovie builds a CatalogMovie from ffprobe output + filename parsing +
// sidecar subtitle discovery. Metadata (title/series/season/episode) is seeded
// from the FILENAME; the DB upsert preserves any later admin edits.
func (s *Service) probeToMovie(path, rel string, size, mtime int64) store.CatalogMovie {
	m := store.CatalogMovie{
		RelPath:   rel,
		Size:      size,
		Mtime:     mtime,
		Container: strings.TrimPrefix(strings.ToLower(filepath.Ext(path)), "."),
	}
	parseFilename(rel, &m)

	// Prober is nil only in tests that don't exercise probing; skip rather
	// than crash the scan.
	if s.Prober != nil {
		pr, err := s.Prober.Probe(path)
		if err != nil {
			s.Log.Warn("ffprobe failed", "rel", rel, "err", err)
		} else {
			applyProbe(pr, &m)
		}
	}
	// Sidecar subtitles: <video basename>*.srt/.vtt/.ass beside the file.
	m.Streams.Subs = append(m.Streams.Subs, s.discoverSidecarSubs(path, rel)...)
	m.HasArt = s.hasArt(path)
	return m
}

// discoverSidecarSubs finds subtitle files sharing the video's basename.
// "Movie.en.srt" → lang "en"; "Movie.srt" → lang "".
func (s *Service) discoverSidecarSubs(videoPath, videoRel string) []store.SubStream {
	dir := filepath.Dir(videoPath)
	base := strings.TrimSuffix(filepath.Base(videoPath),
		filepath.Ext(videoPath))
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []store.SubStream
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		ext := strings.ToLower(filepath.Ext(name))
		if !subExt[ext] || !strings.HasPrefix(name, base) {
			continue
		}
		// Middle segment between base and ext is a language hint, if present.
		mid := strings.TrimSuffix(name[len(base):], filepath.Ext(name))
		lang := strings.Trim(mid, ".")
		relDir := filepath.Dir(videoRel)
		out = append(out, store.SubStream{
			Lang:     lang,
			Codec:    strings.TrimPrefix(ext, "."),
			Text:     true,
			External: filepath.ToSlash(filepath.Join(relDir, name)),
		})
	}
	return out
}

// hasArt reports an admin poster override or a folder.jpg / poster.jpg beside
// the video.
func (s *Service) hasArt(videoPath string) bool {
	// override checked at serve time via ArtVersion; here just embedded/folder.
	for _, n := range []string{"poster.jpg", "folder.jpg", "cover.jpg"} {
		if _, err := os.Stat(filepath.Join(filepath.Dir(videoPath), n)); err == nil {
			return true
		}
	}
	return false
}

// parseFilename seeds title/year/series/season/episode from conventions:
//
//	"Movie Name (2019).mkv"
//	"Show Name/Season 1/S01E03 - Title.mkv"  or  "...1x03..."
func parseFilename(rel string, m *store.CatalogMovie) {
	base := strings.TrimSuffix(filepath.Base(rel), filepath.Ext(rel))
	parts := strings.Split(rel, "/")

	if season, episode, ok := parseEpisode(base); ok {
		m.Kind = "episode"
		m.Season = season
		m.Episode = episode
		// Series name = the top folder if the file sits under one.
		if len(parts) >= 2 {
			m.Series = cleanupName(parts[0])
		}
		m.Title = cleanupName(stripEpisodeToken(base))
		if m.Title == "" {
			m.Title = m.Series
		}
		return
	}
	m.Kind = "movie"
	m.Year = extractYear(base)
	m.Title = cleanupName(stripYear(base))
}

// hasArt / poster override version for ETag busting.
func (s *Service) ArtVersion(m *store.CatalogMovie) int64 {
	if fi, err := os.Stat(s.artOverridePath(m.ID)); err == nil {
		return fi.ModTime().Unix()
	}
	return m.Mtime
}

// SetArtOverride stores an admin-uploaded poster.
func (s *Service) SetArtOverride(id string, data []byte) error {
	p := s.artOverridePath(id)
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o640)
}

// Artwork returns the poster: admin override, else folder.jpg/poster.jpg.
func (s *Service) Artwork(m *store.CatalogMovie) ([]byte, string, bool) {
	if data, err := os.ReadFile(s.artOverridePath(m.ID)); err == nil && len(data) > 0 {
		return data, "image/jpeg", true
	}
	dir := filepath.Dir(s.MoviePath(m))
	for _, n := range []string{"poster.jpg", "folder.jpg", "cover.jpg"} {
		if data, err := os.ReadFile(filepath.Join(dir, n)); err == nil {
			return data, "image/jpeg", true
		}
	}
	return nil, "", false
}

// SidecarSubPath resolves a sidecar subtitle's absolute path (bounds-checked
// to the catalog root by the caller via rel path from the DB).
func (s *Service) SidecarSubPath(rel string) string {
	return filepath.Join(s.Root, filepath.FromSlash(rel))
}

// videoOK reports whether a filename is a supported video container.
func videoOK(name string) bool { return videoExt[strings.ToLower(filepath.Ext(name))] }

// SaveUploadStream streams one uploaded video into the catalog root under a
// sanitized name, atomically (.part + rename), never buffering in memory —
// movie files are gigabytes. Returns the final base name; the caller scans to
// index it. A collision gets a " (2)" suffix so nothing is overwritten.
func (s *Service) SaveUploadStream(filename string, r io.Reader) (string, error) {
	if !videoOK(filename) {
		return "", ErrNotVideo
	}
	if err := s.EnsureRoot(); err != nil {
		return "", err
	}
	ext := filepath.Ext(filename)
	base := sanitizeName(strings.TrimSuffix(filepath.Base(filename), ext))
	name := base + ext
	dst := filepath.Join(s.Root, name)
	for i := 2; ; i++ {
		if _, err := os.Stat(dst); os.IsNotExist(err) {
			break
		}
		name = fmt.Sprintf("%s (%d)%s", base, i, ext)
		dst = filepath.Join(s.Root, name)
	}
	tmp := dst + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o640)
	if err != nil {
		return "", err
	}
	// A large copy buffer cuts syscall count on multi-GB 4K files (the default
	// 32KB buffer means ~300k write calls for a 10GB movie).
	buf := make([]byte, 4<<20)
	_, err = io.CopyBuffer(f, r, buf)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	return name, nil
}

// ErrNotVideo rejects uploads whose extension isn't a known video container.
var ErrNotVideo = errors.New("not a video file")

// sanitizeName keeps a human title (spaces/unicode/case), stripping only
// path-hostile characters — same policy as the music/photos uploaders.
func sanitizeName(raw string) string {
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
		return "movie"
	}
	return s
}

// Trash removes a movie: the FILE moves into `.trash/` (never hard-deleted;
// the scan skips dot-dirs so it won't be re-indexed), then the row is deleted
// (cascading out of watches). A missing file is fine — the row still goes.
func (s *Service) Trash(ctx context.Context, m *store.CatalogMovie) error {
	src := s.MoviePath(m)
	dst := filepath.Join(s.Root, ".trash", filepath.FromSlash(m.RelPath))
	if _, err := os.Stat(src); err == nil {
		if err := os.MkdirAll(filepath.Dir(dst), 0o770); err != nil {
			return err
		}
		if err := os.Rename(src, dst); err != nil {
			return err
		}
	}
	s.RemoveThumbArt(m.ID)
	return s.Store.Write().DeleteMovies(ctx, []string{m.ID})
}

// RemoveThumbArt drops a movie's poster override on delete.
func (s *Service) RemoveThumbArt(id string) {
	_ = os.Remove(s.artOverridePath(id))
}

func atoiSafe(s string) int { n, _ := strconv.Atoi(s); return n }
