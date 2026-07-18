package httpapi

import (
	"bytes"
	"net/http/httptest"
	"testing"
)

func TestAvatarUploadAndFetch(t *testing.T) {
	e := newTestEnv(t)
	tok := e.idp.mint(t, "sub-admin", "venu@example.com", "venu")
	_, grant := e.call(t, "POST", "/v1/setup", "", map[string]any{
		"code": "cafe1234", "id_token": tok})
	access := grant["access_token"].(string)

	put := func(body []byte) int {
		req := httptest.NewRequest("PUT", "/v1/me/avatar", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+access)
		rec := httptest.NewRecorder()
		e.handler.ServeHTTP(rec, req)
		return rec.Code
	}

	// No avatar yet → 404.
	code, _ := e.call(t, "GET", "/v1/me/avatar", access, nil)
	if code != 404 {
		t.Fatalf("empty avatar = %d, want 404", code)
	}

	// Not an image → refused.
	if code := put([]byte("just some text, definitely not an image")); code != 400 {
		t.Fatalf("text upload = %d, want 400", code)
	}

	// A real PNG header → accepted, served back with the right content type.
	png := append([]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A},
		make([]byte, 64)...)
	if code := put(png); code != 200 {
		t.Fatalf("png upload = %d, want 200", code)
	}
	req := httptest.NewRequest("GET", "/v1/me/avatar", nil)
	req.Header.Set("Authorization", "Bearer "+access)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("avatar fetch = %d %q", rec.Code, rec.Header().Get("Content-Type"))
	}
	if rec.Header().Get("ETag") == "" {
		t.Fatalf("avatar missing ETag")
	}

	// Unauthenticated → 401 (it's private).
	code, _ = e.call(t, "GET", "/v1/me/avatar", "", nil)
	if code != 401 {
		t.Fatalf("unauthed avatar = %d, want 401", code)
	}
}
