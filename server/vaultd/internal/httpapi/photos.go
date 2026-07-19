// Photo/video backup endpoints (M3, simple phase). The flow is two steps:
// the client asks which content hashes the server is missing, then uploads
// exactly those — so re-running a backup over a 10k-item camera roll costs
// one cheap POST, not 10k uploads. Upload/check gate on photos:sync (the
// backup-engine action per DESIGN.md); list/content gate on photos:read.
package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"mime"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/photos"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// maxPhotoUpload caps one original. Videos dominate: 6 GiB covers long 4K
// clips without letting a runaway request eat the disk.
const maxPhotoUpload = 6 << 30

// checkPhotoIntegrity verifies at boot that every row's file is actually on
// disk (a stat per row — cheap). It REPORTS ONLY, deliberately: deleting
// rows from filesystem state would wipe the whole index if the pool ever
// failed to mount. Clients self-heal instead — the backup engine reconciles
// its ledger against the server's real listing, so anything reported here
// re-uploads on the next run.
func (s *Server) checkPhotoIntegrity(ctx context.Context) {
	files, err := s.store.Read().AllPhotoFiles(ctx)
	if err != nil || len(files) == 0 {
		return
	}
	var missing, wrongSize int
	for _, f := range files {
		present, sizeOK := s.photos.Exists(f.Username, f.RelPath, f.Size)
		switch {
		case !present:
			missing++
			s.log.Warn("photo integrity: file missing for row",
				"user", f.Username, "rel", f.RelPath, "id", f.ID)
		case !sizeOK:
			wrongSize++
			s.log.Warn("photo integrity: size mismatch",
				"user", f.Username, "rel", f.RelPath, "id", f.ID)
		}
	}
	s.log.Info("photo integrity check",
		"rows", len(files), "missing", missing, "size_mismatch", wrongSize)
}

// POST /v1/photos/check {hashes:[...]}  (photos:sync)
// → {missing:[...]} — the subset the client still needs to upload.
func (s *Server) handlePhotosCheck(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Hashes []string `json:"hashes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	p := PrincipalFrom(r.Context())
	have, err := s.store.Read().ExistingPhotoHashes(r.Context(), p.UserID, req.Hashes)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	missing := []string{}
	for _, h := range req.Hashes {
		if !have[h] {
			missing = append(missing, h)
		}
	}
	s.log.Info("photos check",
		"user", p.Username, "asked", len(req.Hashes), "missing", len(missing))
	writeJSON(w, http.StatusOK, map[string]any{"missing": missing})
}

// POST /v1/photos  (photos:sync) — one original per request, streamed.
// Multipart fields: `taken_at` (unix seconds, optional), `hash` (client's
// sha256, optional but verified when present), then the `file` part LAST so
// the metadata is known before the bytes arrive.
func (s *Server) handlePhotoUpload(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	r.Body = http.MaxBytesReader(w, r.Body, maxPhotoUpload)
	mr, err := r.MultipartReader()
	if err != nil {
		writeErr(w, http.StatusBadRequest, "multipart body required")
		return
	}

	var takenAt time.Time
	var claimedHash string
	var thumb []byte
	for {
		part, err := mr.NextPart()
		if err != nil {
			s.log.Warn("photo rejected: no file part",
				"user", p.Username, "err", err)
			writeErr(w, http.StatusBadRequest, "missing file part")
			return
		}
		name := part.FormName()
		if name == "thumb" {
			// Client-generated JPEG preview (the phone decodes HEIC for
			// free). Bounded; a corrupt/oversized thumb never fails the
			// upload — the original is what matters.
			data, err := io.ReadAll(io.LimitReader(part, maxThumbBytes+1))
			if err == nil && len(data) > 0 && len(data) <= maxThumbBytes &&
				strings.HasPrefix(http.DetectContentType(data), "image/") {
				thumb = data
			}
			continue
		}
		if name != "file" {
			// Small metadata fields — bounded read.
			buf := make([]byte, 128)
			n, _ := part.Read(buf)
			val := strings.TrimSpace(string(buf[:n]))
			switch name {
			case "taken_at":
				if sec, err := strconv.ParseInt(val, 10, 64); err == nil && sec > 0 {
					takenAt = time.Unix(sec, 0)
				}
			case "hash":
				claimedHash = strings.ToLower(val)
			}
			continue
		}

		filename := filepath.Base(part.FileName())
		kind := photos.KindFor(filename)
		if kind == "" {
			// Log the NAME — a whole camera roll once 400'd on a client
			// filename bug and the logs couldn't say why.
			s.log.Warn("photo rejected: not a media filename",
				"user", p.Username, "name", filename)
			writeErr(w, http.StatusBadRequest, "not a photo or video file")
			return
		}

		res, err := s.photos.SaveUpload(p.Username, filename, takenAt, part)
		if err != nil {
			s.fail(w, r, err)
			return
		}
		// The client's hash is a free integrity check: a mismatch means the
		// bytes were damaged in transit — never record a corrupt original.
		if claimedHash != "" && claimedHash != res.Hash {
			_ = s.photos.Remove(p.Username, res.RelPath)
			s.log.Warn("photo rejected: hash mismatch",
				"user", p.Username, "name", filename,
				"claimed", claimedHash[:min(12, len(claimedHash))],
				"actual", res.Hash[:12])
			writeErr(w, http.StatusBadRequest, "hash mismatch — upload corrupted")
			return
		}

		// Same content already backed up → drop the duplicate file, answer
		// with the existing row. Idempotent re-uploads, no wasted disk.
		if existing, err := s.store.Read().PhotoByHash(r.Context(), p.UserID, res.Hash); err == nil {
			_ = s.photos.Remove(p.Username, res.RelPath)
			s.log.Info("photo duplicate ignored",
				"user", p.Username, "name", filename, "id", existing.ID)
			writeJSON(w, http.StatusOK, existing)
			return
		}

		ph := store.Photo{
			RelPath: res.RelPath,
			Hash:    res.Hash,
			Size:    res.Size,
			Mime:    mime.TypeByExtension(strings.ToLower(filepath.Ext(filename))),
			Kind:    kind,
			TakenAt: takenAt.Unix(),
		}
		if takenAt.IsZero() {
			ph.TakenAt = 0
		}
		id, err := s.store.Write().InsertPhoto(r.Context(), p.UserID, ph)
		if err != nil {
			// The file must not outlive a row that never landed.
			_ = s.photos.Remove(p.Username, res.RelPath)
			s.fail(w, r, err)
			return
		}
		if thumb != nil {
			if err := s.photos.SetThumb(id, thumb); err != nil {
				s.log.Warn("thumb write failed", "id", id, "err", err)
			}
		}
		saved, err := s.store.Read().PhotoByID(r.Context(), p.UserID, id)
		if err != nil {
			s.fail(w, r, err)
			return
		}
		saved.HasThumb = s.photos.HasThumb(id)
		// The stored ack — grep `photo stored` in vaultd logs to audit
		// exactly what landed, where, and under which verified hash.
		s.log.Info("photo stored",
			"user", p.Username, "name", filename, "kind", kind,
			"bytes", res.Size, "rel", res.RelPath, "hash", res.Hash[:12],
			"id", id)
		writeJSON(w, http.StatusCreated, saved)
		return
	}
}

// GET /v1/photos?limit=&offset=  (photos:read) — newest capture first.
func (s *Server) handleListPhotos(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	limit, offset := 200, 0
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 500 {
		limit = v
	}
	if v, err := strconv.Atoi(r.URL.Query().Get("offset")); err == nil && v > 0 {
		offset = v
	}
	items, err := s.store.Read().PhotosForUser(r.Context(), p.UserID, limit, offset)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if items == nil {
		items = []store.Photo{}
	}
	for i := range items {
		items[i].HasThumb = s.photos.HasThumb(items[i].ID)
	}
	n, bytes, err := s.store.Read().CountPhotos(r.Context(), p.UserID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"photos": items, "total": n, "total_bytes": bytes,
	})
}

// maxThumbBytes caps one thumbnail — 400px JPEGs run ~30–80 KB.
const maxThumbBytes = 1 << 20

// GET /v1/photos/{id}/thumb  (photos:read) — the small preview that makes
// the timeline scroll. Immutable per id, so cache hard.
func (s *Server) handlePhotoThumb(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	ph, err := s.store.Read().PhotoByID(r.Context(), p.UserID, chi.URLParam(r, "id"))
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	etag := `"t-` + ph.ID + `"`
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	data, err := os.ReadFile(s.photos.ThumbPath(ph.ID))
	if err != nil {
		writeErr(w, http.StatusNotFound, "no thumbnail")
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, max-age=604800, immutable")
	_, _ = w.Write(data)
}

// PUT /v1/photos/{id}/thumb  (photos:sync) — thumbnail backfill for items
// backed up before thumbs existed. Body: raw JPEG bytes.
func (s *Server) handleSetPhotoThumb(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	ph, err := s.store.Read().PhotoByID(r.Context(), p.UserID, chi.URLParam(r, "id"))
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, maxThumbBytes+1))
	if err != nil || len(data) == 0 || len(data) > maxThumbBytes {
		writeErr(w, http.StatusBadRequest, "thumbnail too large or empty")
		return
	}
	if !strings.HasPrefix(http.DetectContentType(data), "image/") {
		writeErr(w, http.StatusBadRequest, "not an image")
		return
	}
	if err := s.photos.SetThumb(ph.ID, data); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// GET /v1/photos/missing-thumbs  (photos:sync) — rows without a thumbnail,
// as (id, hash) pairs: the client maps hash → local asset via its ledger and
// backfills without re-hashing anything.
func (s *Server) handleMissingThumbs(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	// The full row set (paged internally): backfill is a maintenance sweep,
	// not a hot path.
	type pair struct {
		ID   string `json:"id"`
		Hash string `json:"hash"`
	}
	out := []pair{}
	for offset := 0; ; offset += 500 {
		items, err := s.store.Read().PhotosForUser(r.Context(), p.UserID, 500, offset)
		if err != nil {
			s.fail(w, r, err)
			return
		}
		for _, ph := range items {
			if !s.photos.HasThumb(ph.ID) {
				out = append(out, pair{ID: ph.ID, Hash: ph.Hash})
			}
		}
		if len(items) < 500 {
			break
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out})
}

// GET /v1/photos/{id}/content  (photos:read) — the original, Range-capable.
func (s *Server) handlePhotoContent(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	ph, err := s.store.Read().PhotoByID(r.Context(), p.UserID, chi.URLParam(r, "id"))
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	if ph.Mime != "" {
		w.Header().Set("Content-Type", ph.Mime)
	}
	w.Header().Set("Cache-Control", "private, max-age=86400")
	http.ServeFile(w, r, s.photos.PhotoPath(p.Username, ph.RelPath))
}
