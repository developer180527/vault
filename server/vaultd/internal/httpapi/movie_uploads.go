// Legacy movie-upload routes (docs/MOVIES.md), kept at their original paths
// and response shapes so shipped clients keep working. The engine underneath
// is now the SHARED uploads service (music + movies); the on-disk format is
// unchanged, so transfers already in flight resume across the switch.
//
// New clients should prefer the unified /v1/admin/uploads/* API, which is the
// same protocol with an explicit kind.
package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/uploads"
)

// POST /v1/movies/uploads {name, size} → {id, offset}
func (s *Server) handleBeginMovieUpload(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
		Size int64  `json:"size"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	m, err := s.uploads.Begin("movies", req.Name, req.Size)
	if err != nil {
		if errors.Is(err, uploads.ErrRejected) {
			writeErr(w, http.StatusBadRequest, "not a video file")
			return
		}
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	p := PrincipalFrom(r.Context())
	s.log.Info("movie upload begun",
		"user", p.Username, "name", m.Name, "bytes", m.Size, "id", m.ID)
	writeJSON(w, http.StatusCreated, map[string]any{
		"id": m.ID, "name": m.Name, "size": m.Size, "offset": 0,
	})
}

// GET /v1/movies/uploads/{id} → {offset, size} — where to resume from.
// (GET rather than HEAD so the body carries the numbers; HEAD is also routed
// for tus-familiar clients.)
func (s *Server) handleMovieUploadOffset(w http.ResponseWriter, r *http.Request) {
	m, offset, err := s.uploads.Info(chi.URLParam(r, "id"))
	if err != nil {
		writeErr(w, http.StatusNotFound, "no such upload")
		return
	}
	w.Header().Set("Upload-Offset", strconv.FormatInt(offset, 10))
	w.Header().Set("Upload-Length", strconv.FormatInt(m.Size, 10))
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id": m.ID, "name": m.Name, "size": m.Size, "offset": offset,
	})
}

// PATCH /v1/movies/uploads/{id}  (Upload-Offset header + raw chunk body)
// → {offset} after the write. A mismatched offset answers 409 WITH the real
// offset, so the client re-syncs instead of corrupting the file.
func (s *Server) handleMovieUploadChunk(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	offset, err := strconv.ParseInt(r.Header.Get("Upload-Offset"), 10, 64)
	if err != nil || offset < 0 {
		writeErr(w, http.StatusBadRequest, "Upload-Offset header required")
		return
	}
	newOffset, err := s.uploads.AppendChunk(id, offset, r.Body)
	if err != nil {
		if errors.Is(err, uploads.ErrOffsetMismatch) {
			w.Header().Set("Upload-Offset", strconv.FormatInt(newOffset, 10))
			writeJSON(w, http.StatusConflict, map[string]any{
				"error": "offset mismatch", "offset": newOffset,
			})
			return
		}
		if errors.Is(err, uploads.ErrNoUpload) {
			writeErr(w, http.StatusNotFound, "no such upload")
			return
		}
		s.log.Warn("movie chunk failed", "id", id, "err", err)
		writeErr(w, http.StatusInternalServerError, "chunk write failed")
		return
	}
	w.Header().Set("Upload-Offset", strconv.FormatInt(newOffset, 10))
	writeJSON(w, http.StatusOK, map[string]any{"offset": newOffset})
}

// POST /v1/movies/uploads/{id}/finish → moves into the catalog + rescans.
func (s *Server) handleFinishMovieUpload(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	name, err := s.uploads.Finish(id)
	if err != nil {
		if errors.Is(err, uploads.ErrNoUpload) {
			writeErr(w, http.StatusNotFound, "no such upload")
			return
		}
		// Incomplete: the client should read the offset and send the rest.
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if _, _, err := s.movies.Scan(r.Context()); err != nil {
		s.log.Warn("post-upload movie scan failed", "err", err)
	}
	p := PrincipalFrom(r.Context())
	s.log.Info("movie upload finished", "user", p.Username, "name", name)
	s.changes.Bump("movies")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "name": name})
}

// DELETE /v1/movies/uploads/{id} — abandon an upload.
func (s *Server) handleAbortMovieUpload(w http.ResponseWriter, r *http.Request) {
	if err := s.uploads.Abort(chi.URLParam(r, "id")); err != nil {
		writeErr(w, http.StatusNotFound, "no such upload")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
