// Package photos stores camera-roll backups: plain date-sharded originals
// under one root, so duplicating the whole store is a single rsync/zfs-send.
// No content-addressing, no transcodes, no derivatives — the integrity and
// 3-2-1 machinery layers on later without moving a byte (design decision:
// simple first, the sha256 recorded per file seeds the future verification).
//
// Layout: <Root>/users/<username>/<YYYY>/<MM>/<original name>.<ext>
// The root is its own filesystem in production (the HDD pool) — set
// VAULT_PHOTOS_ROOT; it defaults under DataRoot for dev.
package photos

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Service writes and resolves backed-up originals.
type Service struct {
	// Root is the photo store's base directory (the HDD mount in prod).
	Root string
}

// ErrNotMedia rejects uploads whose extension is neither photo nor video.
var ErrNotMedia = errors.New("not a photo or video file")

// Kind extensions — what camera rolls produce. HEIC/HEIF are first-class:
// iPhones shoot them by default.
var photoExt = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".heic": true, ".heif": true,
	".gif": true, ".webp": true, ".dng": true, ".tiff": true, ".bmp": true,
}
var videoExt = map[string]bool{
	".mp4": true, ".mov": true, ".m4v": true, ".webm": true, ".mkv": true,
	".avi": true, ".3gp": true,
}

// KindFor classifies a filename: "photo", "video", or "" (not media).
func KindFor(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	switch {
	case photoExt[ext]:
		return "photo"
	case videoExt[ext]:
		return "video"
	default:
		return ""
	}
}

// userDir is where one user's originals live.
func (s *Service) userDir(username string) string {
	return filepath.Join(s.Root, "users", username)
}

// PhotoPath resolves a stored rel_path (users/<u>/YYYY/MM/name) to disk.
func (s *Service) PhotoPath(username, relPath string) string {
	return filepath.Join(s.userDir(username), filepath.FromSlash(relPath))
}

// sanitizeFilename keeps a human-readable media filename (IMG_1234.HEIC,
// "Beach day.mov") and strips only what's hostile in a path component:
// separators, control chars, reserved punctuation. Same policy as the music
// catalog's uploader.
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
		return "item"
	}
	return s
}

// SaveResult describes one landed original.
type SaveResult struct {
	RelPath string // users/<u>-relative, slash-separated
	Hash    string // sha256 hex, computed while streaming
	Size    int64
}

// SaveUpload streams one original into the store: date-sharded by capture
// time (upload time when unknown), hashed while writing, atomic via
// .part+rename, collision-suffixed so an upload never overwrites. The caller
// checks the returned hash against the DB for dedupe/verification — this
// layer only lands bytes.
func (s *Service) SaveUpload(username, filename string, takenAt time.Time, r io.Reader) (*SaveResult, error) {
	if KindFor(filename) == "" {
		return nil, ErrNotMedia
	}
	if takenAt.IsZero() {
		takenAt = time.Now()
	}
	shard := filepath.Join(
		fmt.Sprintf("%04d", takenAt.Year()), fmt.Sprintf("%02d", takenAt.Month()))
	dir := filepath.Join(s.userDir(username), shard)
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, err
	}

	ext := filepath.Ext(filename)
	base := sanitizeFilename(strings.TrimSuffix(filepath.Base(filename), ext))
	name := base + ext
	dst := filepath.Join(dir, name)
	for i := 2; ; i++ {
		if _, err := os.Stat(dst); os.IsNotExist(err) {
			break
		}
		name = fmt.Sprintf("%s (%d)%s", base, i, ext)
		dst = filepath.Join(dir, name)
	}

	tmp := dst + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o640)
	if err != nil {
		return nil, err
	}
	h := sha256.New()
	size, err := io.Copy(f, io.TeeReader(r, h))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(tmp)
		return nil, err
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return nil, err
	}
	return &SaveResult{
		RelPath: filepath.ToSlash(filepath.Join(shard, name)),
		Hash:    hex.EncodeToString(h.Sum(nil)),
		Size:    size,
	}, nil
}

// Remove deletes a stored original (used to unwind a failed DB insert — the
// file must not outlive a row that never landed).
func (s *Service) Remove(username, relPath string) error {
	return os.Remove(s.PhotoPath(username, relPath))
}

// --- thumbnails ---
//
// Thumbs are CLIENT-generated (the phone decodes HEIC for free and already
// has a thumbnail engine); the server just stores small JPEGs. They live in
// a dot-dir SIBLING of users/ — deliberately outside the originals tree, so
// `rsync .../users` copies exactly the irreplaceable bytes and none of the
// regenerable derivatives.

// ThumbPath is where a photo's thumbnail lives, keyed by row id.
func (s *Service) ThumbPath(id string) string {
	return filepath.Join(s.Root, ".thumbs", filepath.Base(id)+".jpg")
}

// HasThumb reports whether a thumbnail exists for the row.
func (s *Service) HasThumb(id string) bool {
	_, err := os.Stat(s.ThumbPath(id))
	return err == nil
}

// SetThumb stores a thumbnail (already validated by the caller).
func (s *Service) SetThumb(id string, data []byte) error {
	p := s.ThumbPath(id)
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o640)
}

// RemoveThumb drops a thumbnail (row deletion cleanup; missing is fine).
func (s *Service) RemoveThumb(id string) {
	_ = os.Remove(s.ThumbPath(id))
}

// Exists reports whether a stored original is actually on disk, and whether
// its size matches what the DB recorded.
func (s *Service) Exists(username, relPath string, size int64) (present, sizeOK bool) {
	fi, err := os.Stat(s.PhotoPath(username, relPath))
	if err != nil {
		return false, false
	}
	return true, fi.Size() == size
}

// SweepPartials deletes leftover .part files — uploads killed mid-stream by
// a dropped connection or a server restart (a redeploy during an active
// backup run orphans whatever was in flight). Safe at boot: no upload can be
// in progress before the listener starts. Returns how many were removed.
func (s *Service) SweepPartials() int {
	n := 0
	_ = filepath.WalkDir(s.Root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if strings.HasSuffix(d.Name(), ".part") {
			if os.Remove(path) == nil {
				n++
			}
		}
		return nil
	})
	return n
}
