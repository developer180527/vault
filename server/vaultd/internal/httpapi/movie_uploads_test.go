package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// mintMoviesAdmin: setup-bootstrapped admin (holds movies:write).
func mintMoviesAdmin(t *testing.T, e *testEnv) string {
	t.Helper()
	tok := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")
	code, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok})
	if code != 200 {
		t.Fatalf("setup = %d %v", code, grant)
	}
	return grant["access_token"].(string)
}

// patchChunk PATCHes one chunk at [offset] and returns (status, new offset).
func (e *testEnv) patchChunk(t *testing.T, bearer, id string, offset int64,
	chunk []byte) (int, int64) {
	t.Helper()
	req := httptest.NewRequest("PATCH", "/v1/movies/uploads/"+id,
		bytes.NewReader(chunk))
	req.Header.Set("Authorization", "Bearer "+bearer)
	req.Header.Set("Upload-Offset", fmt.Sprint(offset))
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	var out map[string]any
	_ = json.NewDecoder(rec.Body).Decode(&out)
	got, _ := out["offset"].(float64)
	return rec.Code, int64(got)
}

func TestResumableMovieUpload(t *testing.T) {
	e := newTestEnv(t)
	admin := mintMoviesAdmin(t, e)

	// A "movie" in three chunks.
	full := bytes.Repeat([]byte("MATROSKA"), 300) // 2400 bytes
	const chunk = 1000

	code, begun := e.call(t, "POST", "/v1/movies/uploads", admin, map[string]any{
		"name": "Sita Ramam (2022).mkv", "size": len(full)})
	if code != 201 {
		t.Fatalf("begin = %d %v", code, begun)
	}
	id := begun["id"].(string)

	// Chunk 1.
	code, off := e.patchChunk(t, admin, id, 0, full[:chunk])
	if code != 200 || off != chunk {
		t.Fatalf("chunk1 = %d offset %d", code, off)
	}

	// --- the whole point: the client "crashes" and forgets its place. ---
	_, info := e.call(t, "GET", "/v1/movies/uploads/"+id, admin, nil)
	resumeAt := int64(info["offset"].(float64))
	if resumeAt != chunk {
		t.Fatalf("resume offset = %d, want %d", resumeAt, chunk)
	}

	// A stale retry of an already-written chunk is REFUSED with the real
	// offset (writing it would corrupt the file), not silently accepted.
	code, realOff := e.patchChunk(t, admin, id, 0, full[:chunk])
	if code != 409 || realOff != chunk {
		t.Fatalf("stale chunk = %d offset %d, want 409/%d", code, realOff, chunk)
	}

	// Finishing early is refused — a truncated file must never enter the
	// catalog claiming to be a movie.
	if code, _ := e.call(t, "POST", "/v1/movies/uploads/"+id+"/finish",
		admin, nil); code != 400 {
		t.Fatalf("premature finish = %d, want 400", code)
	}

	// Resume from the reported offset and complete.
	code, off = e.patchChunk(t, admin, id, resumeAt, full[chunk:2*chunk])
	if code != 200 || off != 2*chunk {
		t.Fatalf("chunk2 = %d offset %d", code, off)
	}
	code, off = e.patchChunk(t, admin, id, off, full[2*chunk:])
	if code != 200 || off != int64(len(full)) {
		t.Fatalf("chunk3 = %d offset %d", code, off)
	}

	code, fin := e.call(t, "POST", "/v1/movies/uploads/"+id+"/finish", admin, nil)
	if code != 200 {
		t.Fatalf("finish = %d %v", code, fin)
	}

	// The assembled file is byte-identical and in the catalog.
	onDisk := filepath.Join(e.dataRoot, "catalog", "movies",
		"Sita Ramam (2022).mkv")
	got, err := os.ReadFile(onDisk)
	if err != nil {
		t.Fatalf("not in catalog: %v", err)
	}
	if !bytes.Equal(got, full) {
		t.Fatalf("assembled file differs: %d vs %d bytes", len(got), len(full))
	}
	// The scratch .part/.json are gone.
	if _, err := os.Stat(filepath.Join(e.dataRoot, "catalog", "movies",
		".uploads", id+".part")); !os.IsNotExist(err) {
		t.Fatal("part file survived finish")
	}
}

func TestResumableUploadRejectsBadInput(t *testing.T) {
	e := newTestEnv(t)
	admin := mintMoviesAdmin(t, e)

	// Non-video is rejected at BEGIN — a doomed 10GB transfer must fail in
	// the first millisecond, not the last.
	if code, _ := e.call(t, "POST", "/v1/movies/uploads", admin, map[string]any{
		"name": "notes.txt", "size": 100}); code != 400 {
		t.Fatalf("txt begin = %d, want 400", code)
	}
	// Unknown upload id.
	if code, _ := e.call(t, "GET", "/v1/movies/uploads/nope", admin, nil); code != 404 {
		t.Fatalf("unknown id = %d, want 404", code)
	}
	// A member without movies:write can't start an upload.
	member := mintMoviesMember(t, e)
	if code, _ := e.call(t, "POST", "/v1/movies/uploads", member, map[string]any{
		"name": "x.mkv", "size": 10}); code != 403 {
		t.Fatalf("member begin = %d, want 403", code)
	}
}
