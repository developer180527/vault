package uploads

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// newService builds a two-target service over temp dirs, landing files by a
// plain rename into the destination root.
func newService(t *testing.T) (*Service, string, string) {
	t.Helper()
	musicDir := t.TempDir()
	moviesDir := t.TempDir()
	land := func(root string) func(string, string) (string, error) {
		return func(staged, name string) (string, error) {
			dst := filepath.Join(root, name)
			return name, os.Rename(staged, dst)
		}
	}
	return &Service{
		Targets: map[string]Target{
			"music": {
				Dir:   func() string { return musicDir },
				Allow: func(n string) bool { return strings.HasSuffix(n, ".mp3") },
				Land:  land(musicDir),
			},
			"movies": {
				Dir:   func() string { return moviesDir },
				Allow: func(n string) bool { return strings.HasSuffix(n, ".mkv") },
				Land:  land(moviesDir),
			},
		},
	}, musicDir, moviesDir
}

func TestChunkedUploadLandsFile(t *testing.T) {
	s, musicDir, _ := newService(t)
	payload := []byte("hello resumable world")

	m, err := s.Begin("music", "Song.mp3", int64(len(payload)))
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	// Two chunks, to exercise appending at a non-zero offset.
	off, err := s.AppendChunk(m.ID, 0, bytes.NewReader(payload[:8]))
	if err != nil || off != 8 {
		t.Fatalf("chunk 1: off=%d err=%v", off, err)
	}
	off, err = s.AppendChunk(m.ID, 8, bytes.NewReader(payload[8:]))
	if err != nil || off != int64(len(payload)) {
		t.Fatalf("chunk 2: off=%d err=%v", off, err)
	}
	name, err := s.Finish(m.ID)
	if err != nil {
		t.Fatalf("finish: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(musicDir, name))
	if err != nil {
		t.Fatalf("read landed: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("landed content = %q, want %q", got, payload)
	}
	// The session is gone once it lands.
	if _, _, err := s.Info(m.ID); !errors.Is(err, ErrNoUpload) {
		t.Fatalf("session should be cleared, got %v", err)
	}
}

func TestOffsetMismatchReportsRealOffset(t *testing.T) {
	s, _, _ := newService(t)
	m, err := s.Begin("movies", "Film.mkv", 100)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppendChunk(m.ID, 0, bytes.NewReader(make([]byte, 10))); err != nil {
		t.Fatal(err)
	}
	// A stale client retries from 0; it must be refused, not silently
	// corrupt the file — and told where the file actually is.
	got, err := s.AppendChunk(m.ID, 0, bytes.NewReader([]byte("xxx")))
	if !errors.Is(err, ErrOffsetMismatch) {
		t.Fatalf("err = %v, want ErrOffsetMismatch", err)
	}
	if got != 10 {
		t.Fatalf("reported offset = %d, want 10", got)
	}
}

// The whole point of the feature: an interrupted transfer continues from the
// byte the server actually holds, not from zero.
func TestResumeAfterInterruption(t *testing.T) {
	s, _, moviesDir := newService(t)
	payload := bytes.Repeat([]byte("A"), 5000)
	m, err := s.Begin("movies", "Big.mkv", int64(len(payload)))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AppendChunk(m.ID, 0, bytes.NewReader(payload[:1234])); err != nil {
		t.Fatal(err)
	}

	// A brand-new Service (≈ server restarted) must still find the session and
	// report the right resume point — state lives on disk, not in memory.
	s2 := &Service{Targets: s.Targets}
	_, offset, err := s2.Info(m.ID)
	if err != nil {
		t.Fatalf("info after restart: %v", err)
	}
	if offset != 1234 {
		t.Fatalf("resume offset = %d, want 1234", offset)
	}
	if _, err := s2.AppendChunk(m.ID, offset, bytes.NewReader(payload[offset:])); err != nil {
		t.Fatal(err)
	}
	name, err := s2.Finish(m.ID)
	if err != nil {
		t.Fatalf("finish: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(moviesDir, name))
	if !bytes.Equal(got, payload) {
		t.Fatalf("resumed file is %d bytes, want %d", len(got), len(payload))
	}
}

// Sessions written by the pre-unification movie uploader must keep resuming —
// this asserts the on-disk format didn't change.
func TestLegacyMovieSessionStillResumes(t *testing.T) {
	s, _, moviesDir := newService(t)
	dir := filepath.Join(moviesDir, ".uploads")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	const id = "0e2f6c1a-1111-2222-3333-444455556666"
	legacy := map[string]any{
		"id": id, "name": "Old.mkv", "size": 6,
		"created_at": time.Now().Unix(),
	}
	blob, _ := json.Marshal(legacy)
	if err := os.WriteFile(filepath.Join(dir, id+".json"), blob, 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, id+".part"), []byte("abc"), 0o640); err != nil {
		t.Fatal(err)
	}

	m, offset, err := s.Info(id)
	if err != nil {
		t.Fatalf("legacy session unreadable: %v", err)
	}
	if offset != 3 || m.Size != 6 || m.Name != "Old.mkv" {
		t.Fatalf("legacy meta = %+v offset=%d", m, offset)
	}
	if m.Kind != "movies" {
		t.Fatalf("kind = %q, want movies (derived from staging dir)", m.Kind)
	}
	if _, err := s.AppendChunk(id, 3, bytes.NewReader([]byte("def"))); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Finish(id); err != nil {
		t.Fatalf("legacy finish: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(moviesDir, "Old.mkv"))
	if string(got) != "abcdef" {
		t.Fatalf("landed %q, want abcdef", got)
	}
}

func TestRejectsWrongTypeAndKind(t *testing.T) {
	s, _, _ := newService(t)
	// A doomed transfer must fail in the first millisecond, not the last.
	if _, err := s.Begin("music", "Film.mkv", 10); !errors.Is(err, ErrRejected) {
		t.Fatalf("err = %v, want ErrRejected", err)
	}
	if _, err := s.Begin("photos", "x.mp3", 10); !errors.Is(err, ErrBadKind) {
		t.Fatalf("err = %v, want ErrBadKind", err)
	}
}

func TestOverLongChunkIsTruncatedToDeclaredSize(t *testing.T) {
	s, _, _ := newService(t)
	m, err := s.Begin("music", "Short.mp3", 4)
	if err != nil {
		t.Fatal(err)
	}
	// A client that lies about length can't grow the file past what it
	// declared — the writer is capped at the remaining bytes.
	off, err := s.AppendChunk(m.ID, 0, bytes.NewReader(bytes.Repeat([]byte("z"), 100)))
	if err != nil {
		t.Fatal(err)
	}
	if off != 4 {
		t.Fatalf("offset = %d, want 4 (capped at declared size)", off)
	}
}

func TestListAndSweep(t *testing.T) {
	s, _, moviesDir := newService(t)
	fresh, err := s.Begin("movies", "Fresh.mkv", 10)
	if err != nil {
		t.Fatal(err)
	}
	stale, err := s.Begin("music", "Stale.mp3", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.List()) != 2 {
		t.Fatalf("List = %d, want 2", len(s.List()))
	}

	// Age the stale one's files well past the cutoff.
	old := time.Now().Add(-48 * time.Hour)
	musicUploads := filepath.Join(s.Targets["music"].Dir(), ".uploads")
	for _, ext := range []string{".json", ".part"} {
		if err := os.Chtimes(filepath.Join(musicUploads, stale.ID+ext), old, old); err != nil {
			t.Fatal(err)
		}
	}
	if n := s.Sweep(24 * time.Hour); n != 1 {
		t.Fatalf("swept %d, want 1", n)
	}
	if _, _, err := s.Info(stale.ID); !errors.Is(err, ErrNoUpload) {
		t.Fatal("stale session should be gone")
	}
	if _, _, err := s.Info(fresh.ID); err != nil {
		t.Fatalf("fresh session should survive: %v", err)
	}
	_ = moviesDir
}

// An id from the URL must never escape the staging dir.
func TestTraversalIdRejected(t *testing.T) {
	s, _, _ := newService(t)
	for _, bad := range []string{"../../etc/passwd", "..", "/", ""} {
		if _, _, err := s.Info(bad); !errors.Is(err, ErrNoUpload) {
			t.Fatalf("Info(%q) err = %v, want ErrNoUpload", bad, err)
		}
	}
}
