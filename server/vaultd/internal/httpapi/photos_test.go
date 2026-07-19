package httpapi

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// mintPhotosMember registers a member holding photos read+sync — the normal
// camera-backup user.
func mintPhotosMember(t *testing.T, e *testEnv) string {
	t.Helper()
	ctx := t.Context()
	u, err := e.store.Write().CreateUser(ctx, "pia", "pia@example.com", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.store.Write().SetGrant(ctx, u.ID, "photos", []string{"read", "sync"}); err != nil {
		t.Fatal(err)
	}
	tok := e.idp.mint(t, "sub-pia", "pia@example.com", "pia")
	code, grant := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": tok, "device_name": "pia-phone", "platform": "ios"})
	if code != 200 {
		t.Fatalf("register = %d %v", code, grant)
	}
	return grant["access_token"].(string)
}

// uploadPhoto drives POST /v1/photos with a multipart body, the client way:
// metadata fields first, file part last.
func (e *testEnv) uploadPhoto(t *testing.T, bearer, filename string, takenAt int64, data []byte) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	if takenAt > 0 {
		_ = mw.WriteField("taken_at", fmt.Sprint(takenAt))
	}
	sum := sha256.Sum256(data)
	_ = mw.WriteField("hash", hex.EncodeToString(sum[:]))
	fw, err := mw.CreateFormFile("file", filename)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fw.Write(data); err != nil {
		t.Fatal(err)
	}
	_ = mw.Close()

	req := httptest.NewRequest("POST", "/v1/photos", &buf)
	req.Header.Set("Authorization", "Bearer "+bearer)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	var out map[string]any
	_ = json.NewDecoder(rec.Body).Decode(&out)
	return rec.Code, out
}

func TestPhotoBackupUploadDedupeAndServe(t *testing.T) {
	e := newTestEnv(t)
	member := mintPhotosMember(t, e)

	jpeg := []byte("fake-jpeg-bytes-for-the-backup-test")
	sum := sha256.Sum256(jpeg)
	hash := hex.EncodeToString(sum[:])

	// check: nothing backed up yet → our hash is missing.
	code, body := e.call(t, "POST", "/v1/photos/check", member,
		map[string]any{"hashes": []string{hash}})
	if code != 200 || len(body["missing"].([]any)) != 1 {
		t.Fatalf("check = %d %v", code, body)
	}

	// Upload with a capture date → lands sharded under 2024/06.
	taken := int64(1718000000) // 2024-06-10
	code, photo := e.uploadPhoto(t, member, "IMG_0042.jpg", taken, jpeg)
	if code != 201 {
		t.Fatalf("upload = %d %v", code, photo)
	}
	id := photo["id"].(string)
	if photo["kind"] != "photo" || photo["hash"] != hash {
		t.Fatalf("photo row = %v", photo)
	}
	onDisk := filepath.Join(e.dataRoot, "photos", "users", "pia", "2024", "06", "IMG_0042.jpg")
	if _, err := os.Stat(onDisk); err != nil {
		t.Fatalf("original not on disk at %s: %v", onDisk, err)
	}

	// Same bytes again → 200 (not 201), same row, no duplicate file.
	code, dup := e.uploadPhoto(t, member, "IMG_0042 copy.jpg", taken, jpeg)
	if code != 200 || dup["id"] != id {
		t.Fatalf("re-upload = %d %v, want 200 same id", code, dup)
	}

	// check now reports nothing missing.
	_, body = e.call(t, "POST", "/v1/photos/check", member,
		map[string]any{"hashes": []string{hash}})
	if len(body["missing"].([]any)) != 0 {
		t.Fatalf("hash still missing after upload: %v", body)
	}

	// Listing: one item, totals match.
	code, body = e.call(t, "GET", "/v1/photos", member, nil)
	if code != 200 || len(body["photos"].([]any)) != 1 ||
		body["total"].(float64) != 1 {
		t.Fatalf("list = %d %v", code, body)
	}

	// Content round-trips byte-identical.
	req := httptest.NewRequest("GET", "/v1/photos/"+id+"/content", nil)
	req.Header.Set("Authorization", "Bearer "+member)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), jpeg) {
		t.Fatalf("content = %d (%d bytes)", rec.Code, rec.Body.Len())
	}
}

func TestPhotoThumbnails(t *testing.T) {
	e := newTestEnv(t)
	member := mintPhotosMember(t, e)

	// A tiny "JPEG": DetectContentType sniffs image/jpeg from the magic bytes.
	thumbBytes := append([]byte{0xff, 0xd8, 0xff, 0xe0}, bytes.Repeat([]byte{1}, 32)...)

	// 1) Upload WITHOUT a thumb → listed as has_thumb=false, appears in
	// missing-thumbs.
	code, ph := e.uploadPhoto(t, member, "old.jpg", 0, []byte("old-bytes"))
	if code != 201 || ph["has_thumb"] != false {
		t.Fatalf("upload = %d %v", code, ph)
	}
	oldID := ph["id"].(string)
	code, body := e.call(t, "GET", "/v1/photos/missing-thumbs", member, nil)
	if code != 200 || len(body["items"].([]any)) != 1 {
		t.Fatalf("missing-thumbs = %d %v", code, body)
	}

	// 2) Backfill via PUT → served back, has_thumb flips, missing empties.
	req := httptest.NewRequest("PUT", "/v1/photos/"+oldID+"/thumb",
		bytes.NewReader(thumbBytes))
	req.Header.Set("Authorization", "Bearer "+member)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("put thumb = %d", rec.Code)
	}
	req = httptest.NewRequest("GET", "/v1/photos/"+oldID+"/thumb", nil)
	req.Header.Set("Authorization", "Bearer "+member)
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), thumbBytes) {
		t.Fatalf("get thumb = %d (%d bytes)", rec.Code, rec.Body.Len())
	}
	_, body = e.call(t, "GET", "/v1/photos/missing-thumbs", member, nil)
	if len(body["items"].([]any)) != 0 {
		t.Fatalf("missing-thumbs after backfill: %v", body)
	}

	// 3) Upload WITH an inline thumb part → has_thumb from the start.
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	sum := sha256.Sum256([]byte("new-bytes"))
	_ = mw.WriteField("hash", hex.EncodeToString(sum[:]))
	tw, _ := mw.CreateFormFile("thumb", "t.jpg")
	_, _ = tw.Write(thumbBytes)
	fw, _ := mw.CreateFormFile("file", "new.jpg")
	_, _ = fw.Write([]byte("new-bytes"))
	_ = mw.Close()
	req = httptest.NewRequest("POST", "/v1/photos", &buf)
	req.Header.Set("Authorization", "Bearer "+member)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	var out map[string]any
	_ = json.NewDecoder(rec.Body).Decode(&out)
	if rec.Code != 201 || out["has_thumb"] != true {
		t.Fatalf("upload+thumb = %d %v", rec.Code, out)
	}

	// Non-image thumb bytes are refused on backfill.
	req = httptest.NewRequest("PUT", "/v1/photos/"+oldID+"/thumb",
		bytes.NewReader([]byte("plain text, definitely not an image")))
	req.Header.Set("Authorization", "Bearer "+member)
	rec = httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 400 {
		t.Fatalf("text thumb accepted: %d", rec.Code)
	}
}

func TestPhotoUploadRejectsBadInput(t *testing.T) {
	e := newTestEnv(t)
	member := mintPhotosMember(t, e)

	// Not media.
	code, _ := e.uploadPhoto(t, member, "notes.txt", 0, []byte("text"))
	if code != 400 {
		t.Fatalf("txt upload = %d, want 400", code)
	}

	// Corrupted transfer: claimed hash ≠ real bytes → rejected, nothing kept.
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	_ = mw.WriteField("hash", "deadbeef")
	fw, _ := mw.CreateFormFile("file", "IMG_1.jpg")
	_, _ = fw.Write([]byte("real-bytes"))
	_ = mw.Close()
	req := httptest.NewRequest("POST", "/v1/photos", &buf)
	req.Header.Set("Authorization", "Bearer "+member)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	if rec.Code != 400 {
		t.Fatalf("hash mismatch = %d, want 400", rec.Code)
	}
	code, body := e.call(t, "GET", "/v1/photos", member, nil)
	if code != 200 || body["total"].(float64) != 0 {
		t.Fatalf("corrupt upload left a row: %v", body)
	}

	// A member without the photos grant is refused outright.
	stranger := mintMemberWithoutMusic2(t, e)
	if code, _ := e.call(t, "GET", "/v1/photos", stranger, nil); code != 403 {
		t.Fatalf("no-grant list = %d, want 403", code)
	}
	if code, _ := e.call(t, "POST", "/v1/photos/check", stranger,
		map[string]any{"hashes": []string{"x"}}); code != 403 {
		t.Fatalf("no-grant check = %d, want 403", code)
	}
}
