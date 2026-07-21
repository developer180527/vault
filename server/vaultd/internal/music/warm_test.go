package music

import (
	"net/http/httptest"
	"testing"
	"time"
)

// ServeWarm must serve a warmed track straight from RAM with full Range/206
// support (same seek behavior as ServeFile), and report a miss so the caller
// falls back to disk.
func TestServeWarm(t *testing.T) {
	s := &Service{}
	// Miss on an empty (disabled) cache.
	if s.ServeWarm(httptest.NewRecorder(), httptest.NewRequest("GET", "/x", nil), "id1") {
		t.Fatal("ServeWarm hit on a nil cache")
	}

	s.warm = &warmCache{byID: map[string]warmEntry{
		"id1": {data: []byte("0123456789"), modTime: time.Unix(1000, 0), name: "a.m4a"},
	}}

	// Full GET → 200 with the bytes and Accept-Ranges advertised.
	rec := httptest.NewRecorder()
	if !s.ServeWarm(rec, httptest.NewRequest("GET", "/x", nil), "id1") {
		t.Fatal("ServeWarm missed a warmed track")
	}
	if rec.Code != 200 || rec.Body.String() != "0123456789" {
		t.Fatalf("full GET = %d %q", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Accept-Ranges") != "bytes" {
		t.Fatalf("no Accept-Ranges: %v", rec.Header())
	}

	// Range request → 206 with just the slice (proves in-RAM seeking).
	req := httptest.NewRequest("GET", "/x", nil)
	req.Header.Set("Range", "bytes=2-4")
	rec = httptest.NewRecorder()
	s.ServeWarm(rec, req, "id1")
	if rec.Code != 206 || rec.Body.String() != "234" {
		t.Fatalf("range GET = %d %q, want 206 \"234\"", rec.Code, rec.Body.String())
	}

	// Unknown id → miss.
	if s.ServeWarm(httptest.NewRecorder(), httptest.NewRequest("GET", "/x", nil), "nope") {
		t.Fatal("ServeWarm hit on an unknown id")
	}
}
