package httpapi

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

// Profile pictures. Stored as plain files under system/avatars/<userID>.img
// (boring storage: easy to back up, impossible to mismanage). Every signed-in
// user owns exactly their own avatar; the admin panel reads the same files.

const maxAvatarBytes = 2 << 20 // 2 MB — plenty for a profile picture

func (s *Server) avatarPath(userID string) string {
	return filepath.Join(s.dataRoot, "system", "avatars", userID+".img")
}

// GET /v1/me/avatar — the caller's picture, ETag'd by mtime.
func (s *Server) handleGetMyAvatar(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	path := s.avatarPath(p.UserID)
	fi, err := os.Stat(path)
	if err != nil {
		writeErr(w, http.StatusNotFound, "no avatar")
		return
	}
	etag := fmt.Sprintf(`"%d"`, fi.ModTime().UnixNano())
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	w.Header().Set("Content-Type", http.DetectContentType(data))
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	_, _ = w.Write(data)
}

// PUT /v1/me/avatar — raw image bytes in the body. Sniffed server-side: only
// content that actually decodes as image/* lands on disk.
func (s *Server) handlePutMyAvatar(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	data, err := io.ReadAll(io.LimitReader(r.Body, maxAvatarBytes+1))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if len(data) == 0 || len(data) > maxAvatarBytes {
		writeErr(w, http.StatusBadRequest, "avatar must be 1B–2MB")
		return
	}
	if ct := http.DetectContentType(data); len(ct) < 6 || ct[:6] != "image/" {
		writeErr(w, http.StatusBadRequest, "not an image")
		return
	}
	path := s.avatarPath(p.UserID)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		s.fail(w, r, err)
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		s.fail(w, r, err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		s.fail(w, r, err)
		return
	}
	s.log.Info("avatar updated", "user", p.Username, "bytes", len(data))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
