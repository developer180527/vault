// Sync-folder endpoints (M5, foundation). A synced folder is a real folder in
// the user's Files zone plus a provenance record (which device pushed it,
// when, how much). Files land through the existing /v1/files/upload path, so
// they browse/stream/download on every device with no new machinery. This
// file only manages the folder lifecycle + metadata.
package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// GET /v1/synced-folders  (files:read) — the caller's synced folders + meta.
func (s *Server) handleListSyncedFolders(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	folders, err := s.store.Read().SyncedFoldersForUser(r.Context(), p.UserID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if folders == nil {
		folders = []store.SyncedFolder{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"folders": folders})
}

// POST /v1/synced-folders {name, origin_device, origin_platform}  (files:write)
// Creates the folder under the Files zone and records provenance. Returns the
// record plus the file-node id the client uploads into.
func (s *Server) handleCreateSyncedFolder(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name           string `json:"name"`
		OriginDevice   string `json:"origin_device"`
		OriginPlatform string `json:"origin_platform"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		strings.TrimSpace(req.Name) == "" {
		writeErr(w, http.StatusBadRequest, "name required")
		return
	}
	p := PrincipalFrom(r.Context())
	name := strings.TrimSpace(req.Name)

	// The folder lives under the Files zone so it shows in the browser.
	node, err := s.files.Mkdir(p.Username, "files", name)
	if err != nil {
		s.filesErr(w, r, err) // ErrInvalidPath / exists → 4xx
		return
	}
	folder, err := s.store.Write().CreateSyncedFolder(r.Context(), p.UserID, store.SyncedFolder{
		Name:           name,
		RelPath:        "files/" + name,
		OriginDevice:   strings.TrimSpace(req.OriginDevice),
		OriginPlatform: strings.TrimSpace(req.OriginPlatform),
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"folder": folder, "node_id": node.ID,
	})
}

// POST /v1/synced-folders/{id}/touch {file_count, total_bytes}  (files:write)
// The client calls this when a push completes, so the info panel shows the
// last sync time and tally.
func (s *Server) handleTouchSyncedFolder(w http.ResponseWriter, r *http.Request) {
	var req struct {
		FileCount  int   `json:"file_count"`
		TotalBytes int64 `json:"total_bytes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	p := PrincipalFrom(r.Context())
	if err := s.store.Write().TouchSyncedFolder(r.Context(), p.UserID,
		chi.URLParam(r, "id"), req.FileCount, req.TotalBytes); err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// DELETE /v1/synced-folders/{id}  (files:write) — drop the provenance record.
// The folder and its files stay in the user's Files zone.
func (s *Server) handleDeleteSyncedFolder(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	if err := s.store.Write().DeleteSyncedFolder(r.Context(), p.UserID,
		chi.URLParam(r, "id")); err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
