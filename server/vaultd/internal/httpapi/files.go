package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"path"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/files"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// resolveRel turns a client node id (query ?id=... or "" for root) into a
// user-relative path, or writes an error and returns ok=false.
func (s *Server) resolveRel(w http.ResponseWriter, r *http.Request) (string, bool) {
	rel, err := files.DecodeID(r.URL.Query().Get("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid node id")
		return "", false
	}
	return rel, true
}

func (s *Server) username(r *http.Request) (string, error) {
	p := PrincipalFrom(r.Context())
	u, err := s.store.Read().UserByID(r.Context(), p.UserID)
	if err != nil {
		return "", err
	}
	return u.Username, nil
}

// filesErr maps service errors to HTTP status.
func (s *Server) filesErr(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, files.ErrInvalidPath):
		writeErr(w, http.StatusBadRequest, "invalid path")
	case errors.Is(err, files.ErrNotFound), errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not found")
	case errors.Is(err, files.ErrExists):
		writeErr(w, http.StatusConflict, "a file with that name already exists here")
	default:
		s.fail(w, r, err)
	}
}

// GET /v1/files?id=<node>   → children of a folder (empty id = library root)
func (s *Server) handleListFiles(w http.ResponseWriter, r *http.Request) {
	rel, ok := s.resolveRel(w, r)
	if !ok {
		return
	}
	username, err := s.username(r)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	nodes, err := s.files.List(username, rel)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"nodes": nodes})
}

// GET /v1/files/path?id=<node>  → breadcrumb chain
func (s *Server) handleFilePath(w http.ResponseWriter, r *http.Request) {
	rel, ok := s.resolveRel(w, r)
	if !ok {
		return
	}
	username, err := s.username(r)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	chain, err := s.files.PathChain(username, rel)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"nodes": chain})
}

// POST /v1/files/folder {parent_id, name}
func (s *Server) handleMkdir(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ParentID string `json:"parent_id"`
		Name     string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	username, parent, ok := s.userAndParent(w, r, req.ParentID)
	if !ok {
		return
	}
	node, err := s.files.Mkdir(username, parent, req.Name)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, node)
}

// POST /v1/files/rename {id, name}
func (s *Server) handleRenameFile(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	username, rel, ok := s.userAndRel(w, r, req.ID)
	if !ok {
		return
	}
	node, err := s.files.Rename(username, rel, req.Name)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, node)
}

// POST /v1/files/move {id, dest_parent}  — relocate a node into another folder.
func (s *Server) handleMoveFile(w http.ResponseWriter, r *http.Request) {
	s.transfer(w, r, false)
}

// POST /v1/files/copy {id, dest_parent}  — duplicate a node into another folder.
func (s *Server) handleCopyFile(w http.ResponseWriter, r *http.Request) {
	s.transfer(w, r, true)
}

func (s *Server) transfer(w http.ResponseWriter, r *http.Request, copy bool) {
	var req struct {
		ID         string `json:"id"`
		DestParent string `json:"dest_parent"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	username, rel, ok := s.userAndRel(w, r, req.ID)
	if !ok {
		return
	}
	dstParent, err := files.DecodeID(strings.TrimSpace(req.DestParent))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid destination id")
		return
	}
	var node *files.Node
	if copy {
		node, err = s.files.Copy(username, rel, dstParent)
	} else {
		node, err = s.files.Move(username, rel, dstParent)
	}
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, node)
}

// POST /v1/files/trash {id}
func (s *Server) handleTrashFile(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	username, rel, ok := s.userAndRel(w, r, req.ID)
	if !ok {
		return
	}
	if err := s.files.Trash(username, rel); err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// POST /v1/files/upload?parent=<id>&name=<name>   (raw body = bytes)
func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	username, parent, ok := s.userAndParent(w, r, r.URL.Query().Get("parent"))
	if !ok {
		return
	}
	node, err := s.files.Upload(username, parent, path.Base(name), r.Body)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, node)
}

// GET /v1/files/{id}/content   → the file bytes, with Range support (seek).
func (s *Server) handleFileContent(w http.ResponseWriter, r *http.Request) {
	rel, err := files.DecodeID(chi.URLParam(r, "id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid node id")
		return
	}
	username, err := s.username(r)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	f, info, err := s.files.Open(username, rel)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	defer f.Close()
	// http.ServeContent gives us Range/If-Modified-Since/seek for free and
	// streams via the OS (no whole-file buffering).
	http.ServeContent(w, r, info.Name(), info.ModTime(), f)
}

// --- helpers that resolve the caller + a node/parent id ---

func (s *Server) userAndRel(w http.ResponseWriter, r *http.Request, id string) (string, string, bool) {
	rel, err := files.DecodeID(id)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid node id")
		return "", "", false
	}
	username, err := s.username(r)
	if err != nil {
		s.fail(w, r, err)
		return "", "", false
	}
	return username, rel, true
}

func (s *Server) userAndParent(w http.ResponseWriter, r *http.Request, parentID string) (string, string, bool) {
	// parent_id "" = library root, but you can't create directly at the root
	// (only inside a zone) — the service's SafeJoin/validName enforce it.
	rel, err := files.DecodeID(strings.TrimSpace(parentID))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid parent id")
		return "", "", false
	}
	username, err := s.username(r)
	if err != nil {
		s.fail(w, r, err)
		return "", "", false
	}
	return username, rel, true
}
