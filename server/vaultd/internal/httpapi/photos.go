// Photo/video backup endpoints (M3, simple phase). The flow is two steps:
// the client asks which content hashes the server is missing, then uploads
// exactly those — so re-running a backup over a 10k-item camera roll costs
// one cheap POST, not 10k uploads. Upload/check gate on photos:sync (the
// backup-engine action per DESIGN.md); list/content gate on photos:read.
package httpapi

import (
	"encoding/json"
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
	for {
		part, err := mr.NextPart()
		if err != nil {
			writeErr(w, http.StatusBadRequest, "missing file part")
			return
		}
		name := part.FormName()
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
		saved, err := s.store.Read().PhotoByID(r.Context(), p.UserID, id)
		if err != nil {
			s.fail(w, r, err)
			return
		}
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
	n, bytes, err := s.store.Read().CountPhotos(r.Context(), p.UserID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"photos": items, "total": n, "total_bytes": bytes,
	})
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
