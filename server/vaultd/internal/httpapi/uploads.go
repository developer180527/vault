package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/store"
	"github.com/developer180527/vault/vaultd/internal/uploads"
)

// The unified resumable-upload API behind the Administrative service: one
// protocol for music AND movies, distinguished by `kind`. Same engine and
// on-disk format as the legacy /v1/movies/uploads routes.
//
//	POST   /v1/admin/uploads            {kind,name,size} → {id,offset}
//	GET    /v1/admin/uploads                             → in-flight sessions
//	GET    /v1/admin/uploads/{id}                        → {offset,size,...}
//	PATCH  /v1/admin/uploads/{id}       Upload-Offset + raw chunk
//	POST   /v1/admin/uploads/{id}/finish
//	DELETE /v1/admin/uploads/{id}

// RequireAdmin gates a route on the admin role. The manifest advertises the
// Administrative service to admins so the client knows whether to render it,
// but THIS is the enforcement — a member forging the request still gets 403.
func (s *Server) RequireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := PrincipalFrom(r.Context())
		if p == nil {
			writeErr(w, http.StatusUnauthorized, "not authenticated")
			return
		}
		if p.Role != "admin" {
			writeErr(w, http.StatusForbidden, "admin only")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// POST /v1/admin/uploads {kind,name,size}
func (s *Server) handleUploadCreate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Kind string `json:"kind"`
		Name string `json:"name"`
		Size int64  `json:"size"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	m, err := s.uploads.Begin(req.Kind, req.Name, req.Size)
	if err != nil {
		switch {
		case errors.Is(err, uploads.ErrBadKind):
			writeErr(w, http.StatusBadRequest, "kind must be music or movies")
		case errors.Is(err, uploads.ErrRejected):
			writeErr(w, http.StatusUnsupportedMediaType,
				"not a "+req.Kind+" file")
		default:
			writeErr(w, http.StatusBadRequest, err.Error())
		}
		return
	}
	p := PrincipalFrom(r.Context())
	s.log.Info("upload begun", "kind", req.Kind, "user", p.Username,
		"name", m.Name, "bytes", m.Size, "id", m.ID)
	writeJSON(w, http.StatusCreated, map[string]any{
		"id": m.ID, "kind": m.Kind, "name": m.Name, "size": m.Size,
		"offset": 0,
	})
}

// GET /v1/admin/uploads — in-flight sessions, so a client that lost its local
// record (reinstall, second device) can still find and resume them.
func (s *Server) handleUploadList(w http.ResponseWriter, r *http.Request) {
	list := s.uploads.List()
	out := make([]map[string]any, 0, len(list))
	for _, m := range list {
		_, offset, err := s.uploads.Info(m.ID)
		if err != nil {
			continue
		}
		out = append(out, map[string]any{
			"id": m.ID, "kind": m.Kind, "name": m.Name,
			"size": m.Size, "offset": offset, "created_at": m.CreatedAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"uploads": out})
}

// GET /v1/admin/uploads/{id} — THE resume query.
func (s *Server) handleUploadStatus(w http.ResponseWriter, r *http.Request) {
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
		"id": m.ID, "kind": m.Kind, "name": m.Name, "size": m.Size,
		"offset": offset,
	})
}

// PATCH /v1/admin/uploads/{id}
func (s *Server) handleUploadChunk(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	offset, err := strconv.ParseInt(r.Header.Get("Upload-Offset"), 10, 64)
	if err != nil || offset < 0 {
		writeErr(w, http.StatusBadRequest, "Upload-Offset header required")
		return
	}
	next, err := s.uploads.AppendChunk(id, offset, r.Body)
	if err != nil {
		if errors.Is(err, uploads.ErrOffsetMismatch) {
			// Answer WITH the real offset so the client re-syncs in one trip.
			w.Header().Set("Upload-Offset", strconv.FormatInt(next, 10))
			writeJSON(w, http.StatusConflict, map[string]any{
				"error": "offset mismatch", "offset": next,
			})
			return
		}
		if errors.Is(err, uploads.ErrNoUpload) {
			writeErr(w, http.StatusNotFound, "no such upload")
			return
		}
		s.log.Warn("upload chunk failed", "id", id, "err", err)
		writeErr(w, http.StatusInternalServerError, "chunk write failed")
		return
	}
	w.Header().Set("Upload-Offset", strconv.FormatInt(next, 10))
	writeJSON(w, http.StatusOK, map[string]any{"offset": next})
}

// POST /v1/admin/uploads/{id}/finish — land it, index it, tell every client.
func (s *Server) handleUploadFinish(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	m, _, err := s.uploads.Info(id)
	if err != nil {
		writeErr(w, http.StatusNotFound, "no such upload")
		return
	}
	kind := m.Kind
	name, err := s.uploads.Finish(id)
	if err != nil {
		if errors.Is(err, uploads.ErrNoUpload) {
			writeErr(w, http.StatusNotFound, "no such upload")
			return
		}
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	p := PrincipalFrom(r.Context())
	s.log.Info("upload finished", "kind", kind, "user", p.Username, "name", name)

	// Index the new file, then bump the change feed so connected apps refresh
	// without a restart.
	switch kind {
	case "music":
		if _, _, err := s.music.ScanCatalog(r.Context()); err != nil {
			s.log.Warn("post-upload catalog scan failed", "err", err)
		}
		s.changes.Bump("music")
	case "movies":
		if _, _, err := s.movies.Scan(r.Context()); err != nil {
			s.log.Warn("post-upload movie scan failed", "err", err)
		}
		s.changes.Bump("movies")
	}

	// Admin content changes belong in the audit trail, like panel uploads.
	if err := s.store.Write().InsertAudit(r.Context(), store.AuditEntry{
		ActorUser:  p.Username,
		Action:     kind + ".upload",
		TargetKind: kind,
		Summary:    "uploaded from app: " + name,
		RemoteAddr: r.RemoteAddr,
	}); err != nil {
		s.log.Error("audit write failed", "action", "upload", "err", err)
	}

	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "name": name})
}

// DELETE /v1/admin/uploads/{id}
func (s *Server) handleUploadAbort(w http.ResponseWriter, r *http.Request) {
	if err := s.uploads.Abort(chi.URLParam(r, "id")); err != nil {
		writeErr(w, http.StatusNotFound, "no such upload")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
