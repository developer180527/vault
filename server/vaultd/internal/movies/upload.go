package movies

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Resumable uploads (docs/MOVIES.md). A 10 GB single-request POST is
// all-or-nothing: one dropped connection and the whole transfer restarts. So
// large uploads are chunked, and each chunk is its own request.
//
// The design point worth keeping: **the .part file's SIZE is the offset**.
// There is no separate progress record to drift out of sync with the bytes on
// disk — crash, restart, or a half-written chunk all self-describe. A client
// that lost its place just asks for the offset and continues.

// uploadsDir holds in-flight uploads; a dot-dir so the scanner skips it.
func (s *Service) uploadsDir() string { return filepath.Join(s.Root, ".uploads") }

func (s *Service) partPath(id string) string {
	return filepath.Join(s.uploadsDir(), filepath.Base(id)+".part")
}

func (s *Service) metaPath(id string) string {
	return filepath.Join(s.uploadsDir(), filepath.Base(id)+".json")
}

// UploadMeta is the small sidecar describing an in-flight upload.
type UploadMeta struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	CreatedAt int64  `json:"created_at"`
}

var (
	// ErrNoUpload  — unknown/expired upload id.
	ErrNoUpload = errors.New("no such upload")
	// ErrOffsetMismatch — the client's offset isn't where the file actually
	// is. It must re-read the offset and continue from there; blindly writing
	// would corrupt the file.
	ErrOffsetMismatch = errors.New("offset mismatch")
)

// BeginUpload reserves an upload for [name] of [size] bytes and returns its
// id. Rejects non-video names up front so a doomed 10 GB transfer fails in
// the first millisecond rather than the last.
func (s *Service) BeginUpload(name string, size int64) (*UploadMeta, error) {
	if !videoOK(name) {
		return nil, ErrNotVideo
	}
	if size <= 0 {
		return nil, errors.New("size required")
	}
	if err := os.MkdirAll(s.uploadsDir(), 0o750); err != nil {
		return nil, err
	}
	// Opaque id: it's a URL path segment AND a filename, so it must never
	// carry the movie's name — spaces and parens ("Sita Ramam (2022).mkv")
	// produced unusable URLs. The display name lives in the metadata.
	m := &UploadMeta{
		ID:        uuid.NewString(),
		Name:      filepath.Base(name),
		Size:      size,
		CreatedAt: time.Now().Unix(),
	}
	blob, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(s.metaPath(m.ID), blob, 0o640); err != nil {
		return nil, err
	}
	// Create the empty part file so the offset is immediately readable.
	f, err := os.OpenFile(s.partPath(m.ID), os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		return nil, err
	}
	return m, f.Close()
}

// UploadInfo returns an upload's metadata and how many bytes have landed.
func (s *Service) UploadInfo(id string) (*UploadMeta, int64, error) {
	blob, err := os.ReadFile(s.metaPath(id))
	if err != nil {
		return nil, 0, ErrNoUpload
	}
	var m UploadMeta
	if err := json.Unmarshal(blob, &m); err != nil {
		return nil, 0, ErrNoUpload
	}
	fi, err := os.Stat(s.partPath(id))
	if err != nil {
		return nil, 0, ErrNoUpload
	}
	return &m, fi.Size(), nil
}

// AppendChunk writes one chunk at [offset], which MUST equal the current
// length — that's what makes a retried or out-of-order chunk safe to reject
// instead of silently corrupting the file. Returns the new offset.
func (s *Service) AppendChunk(id string, offset int64, r io.Reader) (int64, error) {
	m, cur, err := s.UploadInfo(id)
	if err != nil {
		return 0, err
	}
	if offset != cur {
		return cur, ErrOffsetMismatch
	}
	f, err := os.OpenFile(s.partPath(id), os.O_WRONLY|os.O_APPEND, 0o640)
	if err != nil {
		return 0, err
	}
	buf := make([]byte, 4<<20)
	n, copyErr := io.CopyBuffer(f, io.LimitReader(r, m.Size-cur), buf)
	// fsync: a chunk the client believes landed must survive a power cut,
	// otherwise resume would silently skip bytes.
	syncErr := f.Sync()
	closeErr := f.Close()
	if copyErr != nil {
		// Partial writes are FINE — the file's size is the truth, and the
		// client re-reads it to continue. Report progress, not failure.
		return cur + n, nil
	}
	if syncErr != nil {
		return cur + n, syncErr
	}
	if closeErr != nil {
		return cur + n, closeErr
	}
	return cur + n, nil
}

// FinishUpload verifies the full size arrived, then atomically moves the file
// into the catalog under a collision-safe name. Returns the final base name.
func (s *Service) FinishUpload(id string) (string, error) {
	m, cur, err := s.UploadInfo(id)
	if err != nil {
		return "", err
	}
	if cur != m.Size {
		return "", fmt.Errorf("incomplete: %d of %d bytes", cur, m.Size)
	}
	if err := s.EnsureRoot(); err != nil {
		return "", err
	}
	ext := filepath.Ext(m.Name)
	base := sanitizeName(strings.TrimSuffix(m.Name, ext))
	name := base + ext
	dst := filepath.Join(s.Root, name)
	for i := 2; ; i++ {
		if _, err := os.Stat(dst); os.IsNotExist(err) {
			break
		}
		name = fmt.Sprintf("%s (%d)%s", base, i, ext)
		dst = filepath.Join(s.Root, name)
	}
	if err := os.Rename(s.partPath(id), dst); err != nil {
		return "", err
	}
	_ = os.Remove(s.metaPath(id))
	return name, nil
}

// AbortUpload discards an in-flight upload.
func (s *Service) AbortUpload(id string) error {
	if _, _, err := s.UploadInfo(id); err != nil {
		return err
	}
	_ = os.Remove(s.partPath(id))
	_ = os.Remove(s.metaPath(id))
	return nil
}

// SweepUploads deletes in-flight uploads older than [maxAge] — abandoned
// transfers must not silently fill the pool. Called at boot. Returns the
// count removed.
func (s *Service) SweepUploads(maxAge time.Duration) int {
	entries, err := os.ReadDir(s.uploadsDir())
	if err != nil {
		return 0
	}
	cutoff := time.Now().Add(-maxAge)
	n := 0
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(e.Name(), ".json")
		info, err := e.Info()
		if err != nil || info.ModTime().After(cutoff) {
			continue
		}
		// Touch-based: an upload actively receiving chunks keeps its .part
		// file fresh, so age off the PART's mtime, not the metadata's.
		if pfi, perr := os.Stat(s.partPath(id)); perr == nil &&
			pfi.ModTime().After(cutoff) {
			continue
		}
		_ = os.Remove(s.partPath(id))
		_ = os.Remove(s.metaPath(id))
		n++
	}
	return n
}
