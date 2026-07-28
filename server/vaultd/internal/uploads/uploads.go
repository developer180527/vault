// Package uploads implements RESUMABLE uploads for large media, shared by the
// music catalog and the movie library. A 10 GB single-request POST is
// all-or-nothing: one dropped connection and the whole transfer restarts. Here
// a drop costs one chunk, and the client can resume days later.
//
// This generalizes the movie uploader that came first; the on-disk format is
// UNCHANGED, so uploads already in flight keep resuming across the switch.
//
// A session is two files in a staging dot-dir inside the destination root
// (scanners skip dot-dirs):
//
//	<root>/.uploads/<id>.part  — bytes received so far (append-only)
//	<root>/.uploads/<id>.json  — {id, name, size, created_at}
//
// Two properties carry the design:
//
//   - **The .part file's SIZE is the offset.** No progress counter exists to
//     drift out of sync with the bytes on disk — a crash, a restart, or a
//     half-written chunk all self-describe. A client that lost its place just
//     asks for the offset and continues.
//   - **Staging lives inside the destination root**, so finishing is an atomic
//     same-filesystem rename rather than copying tens of gigabytes twice.
//
// A session's KIND is implied by which target's staging dir holds it, so no
// kind is stored — which is why pre-existing movie sessions still parse.
package uploads

import (
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"encoding/json"

	"github.com/google/uuid"
)

var (
	// ErrNoUpload — unknown/expired upload id.
	ErrNoUpload = errors.New("no such upload")
	// ErrOffsetMismatch — the client's offset isn't where the file actually
	// is. It must re-read the offset and continue from there; blindly writing
	// would corrupt the file.
	ErrOffsetMismatch = errors.New("offset mismatch")
	// ErrBadKind — no such upload target.
	ErrBadKind = errors.New("unknown upload kind")
	// ErrRejected — the filename's extension isn't accepted by the target.
	ErrRejected = errors.New("file type not accepted")
)

// Target is one destination the uploader can land files into. Supplied by the
// caller, so this package needs no knowledge of the music or movie services.
type Target struct {
	// Dir returns the destination root; staging is <Dir>/.uploads.
	Dir func() string
	// Allow gates a filename by extension (audio/video container check).
	Allow func(name string) bool
	// Land moves a completed staged file into the destination under a
	// sanitized, collision-free name and returns that name.
	Land func(stagedPath, filename string) (string, error)
}

// Meta is the sidecar describing an in-flight upload. Field names are frozen:
// they're the on-disk format shared with sessions created before unification.
type Meta struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	CreatedAt int64  `json:"created_at"`

	// Kind is derived from the staging dir at read time, never persisted.
	Kind string `json:"-"`
}

type Service struct {
	Targets map[string]Target
	Log     *slog.Logger

	mu    sync.Mutex
	locks map[string]*sync.Mutex // per-session: serializes concurrent chunks
}

func (s *Service) lockFor(id string) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.locks == nil {
		s.locks = map[string]*sync.Mutex{}
	}
	m, ok := s.locks[id]
	if !ok {
		m = &sync.Mutex{}
		s.locks[id] = m
	}
	return m
}

func (s *Service) forget(id string) {
	s.mu.Lock()
	delete(s.locks, id)
	s.mu.Unlock()
}

// Kinds lists the configured targets.
func (s *Service) Kinds() []string {
	out := make([]string, 0, len(s.Targets))
	for k := range s.Targets {
		out = append(out, k)
	}
	return out
}

func (s *Service) dirFor(kind string) (string, error) {
	t, ok := s.Targets[kind]
	if !ok {
		return "", ErrBadKind
	}
	return filepath.Join(t.Dir(), ".uploads"), nil
}

// locate finds which kind owns [id] and returns its paths. filepath.Base on
// the id keeps a hostile path segment from escaping the staging dir.
func (s *Service) locate(id string) (kind, meta, part string, err error) {
	safe := filepath.Base(id)
	if safe == "" || safe == "." || safe == string(filepath.Separator) {
		return "", "", "", ErrNoUpload
	}
	for k := range s.Targets {
		dir, derr := s.dirFor(k)
		if derr != nil {
			continue
		}
		m := filepath.Join(dir, safe+".json")
		if _, statErr := os.Stat(m); statErr == nil {
			return k, m, filepath.Join(dir, safe+".part"), nil
		}
	}
	return "", "", "", ErrNoUpload
}

// Begin reserves an upload of [size] bytes for [name] under [kind]. Rejects a
// bad extension up front so a doomed 10 GB transfer fails in the first
// millisecond rather than the last.
func (s *Service) Begin(kind, name string, size int64) (*Meta, error) {
	t, ok := s.Targets[kind]
	if !ok {
		return nil, ErrBadKind
	}
	if !t.Allow(name) {
		return nil, ErrRejected
	}
	if size <= 0 {
		return nil, errors.New("size required")
	}
	dir, err := s.dirFor(kind)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, err
	}
	// Opaque id: it's a URL path segment AND a filename, so it must never
	// carry the media's name — spaces and parens ("Sita Ramam (2022).mkv")
	// produced unusable URLs. The display name lives in the metadata.
	m := &Meta{
		ID:        uuid.NewString(),
		Name:      filepath.Base(name),
		Size:      size,
		CreatedAt: time.Now().Unix(),
		Kind:      kind,
	}
	blob, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(dir, m.ID+".json"), blob, 0o640); err != nil {
		return nil, err
	}
	// Create the empty part file so the offset is immediately readable.
	f, err := os.OpenFile(filepath.Join(dir, m.ID+".part"),
		os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		_ = os.Remove(filepath.Join(dir, m.ID+".json"))
		return nil, err
	}
	return m, f.Close()
}

// Info returns an upload's metadata and how many bytes have landed.
func (s *Service) Info(id string) (*Meta, int64, error) {
	kind, meta, part, err := s.locate(id)
	if err != nil {
		return nil, 0, err
	}
	blob, err := os.ReadFile(meta)
	if err != nil {
		return nil, 0, ErrNoUpload
	}
	var m Meta
	if err := json.Unmarshal(blob, &m); err != nil {
		return nil, 0, ErrNoUpload
	}
	m.Kind = kind
	fi, err := os.Stat(part)
	if err != nil {
		return nil, 0, ErrNoUpload
	}
	return &m, fi.Size(), nil
}

// AppendChunk writes one chunk at [offset], which MUST equal the current
// length — that's what makes a retried or out-of-order chunk safe to reject
// instead of silently corrupting the file. Returns the new offset.
func (s *Service) AppendChunk(id string, offset int64, r io.Reader) (int64, error) {
	lock := s.lockFor(id)
	lock.Lock()
	defer lock.Unlock()

	m, cur, err := s.Info(id)
	if err != nil {
		return 0, err
	}
	if offset != cur {
		return cur, ErrOffsetMismatch
	}
	_, _, part, err := s.locate(id)
	if err != nil {
		return 0, err
	}
	f, err := os.OpenFile(part, os.O_WRONLY|os.O_APPEND, 0o640)
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

// Finish verifies the full size arrived, then hands the staged file to the
// target to land. Returns the final name in the library.
func (s *Service) Finish(id string) (string, error) {
	lock := s.lockFor(id)
	lock.Lock()
	defer lock.Unlock()

	m, cur, err := s.Info(id)
	if err != nil {
		return "", err
	}
	if cur != m.Size {
		return "", fmt.Errorf("incomplete: %d of %d bytes", cur, m.Size)
	}
	t, ok := s.Targets[m.Kind]
	if !ok {
		return "", ErrBadKind
	}
	_, meta, part, err := s.locate(id)
	if err != nil {
		return "", err
	}
	name, err := t.Land(part, m.Name)
	if err != nil {
		return "", err
	}
	_ = os.Remove(meta)
	s.forget(id)
	return name, nil
}

// Abort discards an in-flight upload.
func (s *Service) Abort(id string) error {
	_, meta, part, err := s.locate(id)
	if err != nil {
		return err
	}
	lock := s.lockFor(id)
	lock.Lock()
	defer lock.Unlock()
	_ = os.Remove(part)
	_ = os.Remove(meta)
	s.forget(id)
	return nil
}

// List returns every in-flight session across all kinds, so a client that lost
// its local record can still discover and resume its uploads.
func (s *Service) List() []Meta {
	var out []Meta
	for kind := range s.Targets {
		dir, err := s.dirFor(kind)
		if err != nil {
			continue
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
				continue
			}
			id := strings.TrimSuffix(e.Name(), ".json")
			if m, _, err := s.Info(id); err == nil {
				out = append(out, *m)
			}
		}
	}
	return out
}

// Sweep deletes in-flight uploads older than [maxAge] — abandoned transfers
// must not silently fill the pool. Called at boot. Returns the count removed.
func (s *Service) Sweep(maxAge time.Duration) int {
	cutoff := time.Now().Add(-maxAge)
	n := 0
	for kind := range s.Targets {
		dir, err := s.dirFor(kind)
		if err != nil {
			continue
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
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
			part := filepath.Join(dir, id+".part")
			if pfi, perr := os.Stat(part); perr == nil &&
				pfi.ModTime().After(cutoff) {
				continue
			}
			_ = os.Remove(part)
			_ = os.Remove(filepath.Join(dir, id+".json"))
			n++
			if s.Log != nil {
				s.Log.Info("swept abandoned upload", "kind", kind, "id", id)
			}
		}
	}
	return n
}
