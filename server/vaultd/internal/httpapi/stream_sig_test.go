package httpapi

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// Signed stream URLs must work with NO Authorization header at all — that's
// the whole point (playback outliving the 15-minute bearer) — while tampered
// or expired signatures fail closed.
func TestSignedStreamURLs(t *testing.T) {
	e := newTestEnv(t)
	tok := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")
	_, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok})
	access := grant["access_token"].(string)

	// Personal zone track + catalog track.
	e.seedSong(t, "song.mp3", "userbytes")
	e.seedCatalogSong(t, "shared.mp3", "catalogbytes")
	e.call(t, "POST", "/v1/music/catalog/scan", access, nil)

	// Lists carry stream_url.
	_, body := e.call(t, "GET", "/v1/music/tracks", access, nil)
	userTrack := body["tracks"].([]any)[0].(map[string]any)
	userStream, _ := userTrack["stream_url"].(string)
	if userStream == "" || !strings.Contains(userStream, "sig=") {
		t.Fatalf("personal stream_url missing: %v", userTrack)
	}
	_, body = e.call(t, "GET", "/v1/music/catalog", access, nil)
	catTrack := body["tracks"].([]any)[0].(map[string]any)
	catStream, _ := catTrack["stream_url"].(string)
	if catStream == "" || !strings.Contains(catStream, "sig=") {
		t.Fatalf("catalog stream_url missing: %v", catTrack)
	}

	// Both stream WITHOUT any bearer.
	for _, u := range []string{userStream, catStream} {
		req := httptest.NewRequest("GET", u, nil)
		rec := httptest.NewRecorder()
		e.handler.ServeHTTP(rec, req)
		if rec.Code != 200 {
			t.Fatalf("signed stream %s = %d %s", u, rec.Code, rec.Body.String())
		}
	}

	// Tampered signature → 401.
	parsed, _ := url.Parse(catStream)
	q := parsed.Query()
	q.Set("sig", strings.Repeat("0", 64))
	parsed.RawQuery = q.Encode()
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, httptest.NewRequest("GET", parsed.String(), nil))
	if rec.Code != 401 {
		t.Fatalf("tampered sig = %d, want 401", rec.Code)
	}

	// Expired timestamp → 401 (sig covers exp, so changing it also fails).
	q = parsed.Query()
	q.Set("exp", "1000000000") // 2001
	parsed.RawQuery = q.Encode()
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, httptest.NewRequest("GET", parsed.String(), nil))
	if rec.Code != 401 {
		t.Fatalf("expired = %d, want 401", rec.Code)
	}

	// No sig, no bearer → 401; no sig + bearer still works (compat path).
	base := strings.Split(catStream, "?")[0]
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, httptest.NewRequest("GET", base, nil))
	if rec.Code != 401 {
		t.Fatalf("bare stream = %d, want 401", rec.Code)
	}
	req := httptest.NewRequest("GET", base, nil)
	req.Header.Set("Authorization", "Bearer "+access)
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("bearer stream = %d, want 200", rec.Code)
	}
}
