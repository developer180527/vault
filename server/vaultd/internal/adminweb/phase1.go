package adminweb

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/library"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// Phase 1 (ADMIN.md §10): Users & grants + Catalog management. All handlers
// run behind requireAdmin (session + role recheck + same-origin on POST);
// blast-radius guards (§5) are enforced HERE, server-side — the UI hiding a
// button is never the protection.

// handleUserAvatar serves a user's profile picture (the same file the API's
// /v1/me/avatar writes) for the users table. No picture → an initial-letter
// SVG, so the template never needs script-based fallbacks (the panel's CSP
// allows no JS at all).
func (s *Server) handleUserAvatar(w http.ResponseWriter, r *http.Request) {
	id := filepath.Base(chi.URLParam(r, "id"))
	path := filepath.Join(s.music.DataRoot, "system", "avatars", id+".img")
	if data, err := os.ReadFile(path); err == nil {
		w.Header().Set("Content-Type", http.DetectContentType(data))
		w.Header().Set("Cache-Control", "private, max-age=300")
		_, _ = w.Write(data)
		return
	}
	initial := "?"
	if u, err := s.store.Read().UserByID(r.Context(), id); err == nil &&
		u.Username != "" {
		initial = strings.ToUpper(u.Username[:1])
	}
	w.Header().Set("Content-Type", "image/svg+xml")
	w.Header().Set("Cache-Control", "private, max-age=300")
	fmt.Fprintf(w, `<svg xmlns="http://www.w3.org/2000/svg" width="76" height="76">`+
		`<circle cx="38" cy="38" r="38" fill="#2b2b36"/>`+
		`<text x="38" y="50" text-anchor="middle" font-family="sans-serif" `+
		`font-size="34" fill="#c9c9d4">%s</text></svg>`, initial)
}

// redirectMsg bounces back to [path] with a flash message in the query.
func redirectMsg(w http.ResponseWriter, r *http.Request, path, msg string) {
	http.Redirect(w, r, path+"?msg="+url.QueryEscape(msg), http.StatusSeeOther)
}

// ---- Users & grants ----

type userRow struct {
	store.User
	Devices int
	Pending bool // invited, no OIDC identity bound yet
}

func (s *Server) handleUsers(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	users, err := s.store.Read().ListUsers(ctx)
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, "Could not list users.")
		return
	}
	rows := make([]userRow, 0, len(users))
	for _, u := range users {
		devs, _ := s.store.Read().ListDevices(ctx, u.ID)
		rows = append(rows, userRow{
			User: u, Devices: len(devs), Pending: u.OIDCSubject == "",
		})
	}
	s.render(w, "users.html", map[string]any{
		"User": userFrom(r), "Active": "users",
		"Rows": rows, "Msg": r.URL.Query().Get("msg"),
	})
}

func (s *Server) handleCreateInvite(w http.ResponseWriter, r *http.Request) {
	username := library.Sanitize(r.FormValue("username"), "")
	email := strings.TrimSpace(r.FormValue("email"))
	if username == "" || !strings.Contains(email, "@") {
		redirectMsg(w, r, "/users", "Invite needs a username and a valid email.")
		return
	}
	// Invited users bind their Pocket ID identity on first login (by email).
	if _, err := s.store.Write().CreateUser(
		r.Context(), username, email, "", "member", "", ""); err != nil {
		redirectMsg(w, r, "/users", "Could not invite: username or email already in use.")
		return
	}
	s.log.Info("admin: user invited", "username", username,
		"by", userFrom(r).Username)
	s.audit(r, "user.invite", "user", username, "invited via "+email)
	redirectMsg(w, r, "/users",
		fmt.Sprintf("Invited %s — they sign in with Pocket ID (%s) to activate.",
			username, email))
}

func (s *Server) targetUser(w http.ResponseWriter, r *http.Request) (*store.User, bool) {
	u, err := s.store.Read().UserByID(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		s.renderError(w, http.StatusNotFound, "No such user.")
		return nil, false
	}
	return u, true
}

func (s *Server) handleUserDetail(w http.ResponseWriter, r *http.Request) {
	target, ok := s.targetUser(w, r)
	if !ok {
		return
	}
	ctx := r.Context()
	grants, _ := s.store.Read().GrantsForUser(ctx, target.ID)
	devices, _ := s.store.Read().ListDevices(ctx, target.ID)

	// services × actions matrix, pre-checked from current grants.
	type cell struct {
		Service, Action string
		Checked         bool
	}
	matrix := make(map[string][]cell, len(store.KnownServices))
	for _, svc := range store.KnownServices {
		held := map[string]bool{}
		for _, a := range grants[svc] {
			held[a] = true
		}
		row := make([]cell, 0, len(store.KnownActions))
		for _, a := range store.KnownActions {
			row = append(row, cell{Service: svc, Action: a, Checked: held[a]})
		}
		matrix[svc] = row
	}

	// Backup posture: how much of this member's camera roll is safe here.
	photoN, photoBytes, photoLast, _ := s.store.Read().PhotoStatsForUser(ctx, target.ID)

	s.render(w, "user_detail.html", map[string]any{
		"User": userFrom(r), "Active": "users",
		"Target": target, "Self": target.ID == userFrom(r).ID,
		"Pending":  target.OIDCSubject == "",
		"Services": store.KnownServices, "Matrix": matrix,
		"Devices": devices, "Msg": r.URL.Query().Get("msg"),
		"PhotoCount": photoN, "PhotoBytes": photoBytes, "PhotoLast": photoLast,
		"HasPhotosGrant": len(grants["photos"]) > 0 || target.Role == "admin",
	})
}

func (s *Server) handleSaveGrants(w http.ResponseWriter, r *http.Request) {
	target, ok := s.targetUser(w, r)
	if !ok {
		return
	}
	if err := r.ParseForm(); err != nil {
		s.renderError(w, http.StatusBadRequest, "Bad form.")
		return
	}
	ctx := r.Context()
	back := "/users/" + target.ID
	for _, svc := range store.KnownServices {
		actions := make([]string, 0, len(store.KnownActions))
		for _, a := range store.KnownActions {
			if r.Form.Get("grant/"+svc+"/"+a) == "on" {
				actions = append(actions, a)
			}
		}
		var err error
		if len(actions) == 0 {
			err = s.store.Write().RemoveGrant(ctx, target.ID, svc)
		} else {
			err = s.store.Write().SetGrant(ctx, target.ID, svc, actions)
		}
		if err != nil {
			redirectMsg(w, r, back, "Saving grants failed — check the logs.")
			return
		}
	}
	s.log.Info("admin: grants saved", "target", target.Username,
		"by", userFrom(r).Username)
	s.audit(r, "user.grants", "user", target.ID, "grant matrix updated for "+target.Username)
	redirectMsg(w, r, back, "Grants saved.")
}

func (s *Server) handleSetStatus(w http.ResponseWriter, r *http.Request) {
	target, ok := s.targetUser(w, r)
	if !ok {
		return
	}
	back := "/users/" + target.ID
	next := r.FormValue("status")
	if next != "active" && next != "disabled" {
		s.renderError(w, http.StatusBadRequest, "Bad status.")
		return
	}
	// §5 guards: never your own account; never strand the server without an
	// active admin.
	if target.ID == userFrom(r).ID {
		redirectMsg(w, r, back, "You can't disable your own account.")
		return
	}
	if next == "disabled" && target.Role == "admin" && target.Status == "active" {
		if n, _ := s.store.Read().CountActiveAdmins(r.Context()); n <= 1 {
			redirectMsg(w, r, back, "Refused: that is the last active admin.")
			return
		}
	}
	if err := s.store.Write().SetUserStatus(r.Context(), target.ID, next); err != nil {
		redirectMsg(w, r, back, "Status change failed.")
		return
	}
	s.log.Info("admin: status changed", "target", target.Username,
		"status", next, "by", userFrom(r).Username)
	s.audit(r, "user.status", "user", target.ID, target.Username+" -> "+next)
	redirectMsg(w, r, back, "Account "+next+".")
}

func (s *Server) handleSetRole(w http.ResponseWriter, r *http.Request) {
	target, ok := s.targetUser(w, r)
	if !ok {
		return
	}
	back := "/users/" + target.ID
	next := r.FormValue("role")
	if next != "admin" && next != "member" {
		s.renderError(w, http.StatusBadRequest, "Bad role.")
		return
	}
	if target.ID == userFrom(r).ID {
		redirectMsg(w, r, back, "You can't change your own role.")
		return
	}
	if next == "member" && target.Role == "admin" && target.Status == "active" {
		if n, _ := s.store.Read().CountActiveAdmins(r.Context()); n <= 1 {
			redirectMsg(w, r, back, "Refused: that is the last active admin.")
			return
		}
	}
	if err := s.store.Write().SetUserRole(r.Context(), target.ID, next); err != nil {
		redirectMsg(w, r, back, "Role change failed.")
		return
	}
	s.log.Info("admin: role changed", "target", target.Username,
		"role", next, "by", userFrom(r).Username)
	s.audit(r, "user.role", "user", target.ID, target.Username+" -> "+next)
	redirectMsg(w, r, back, "Role set to "+next+".")
}

func (s *Server) handleRevokeDevice(w http.ResponseWriter, r *http.Request) {
	target, ok := s.targetUser(w, r)
	if !ok {
		return
	}
	back := "/users/" + target.ID
	if err := s.store.Write().RevokeDevice(
		r.Context(), chi.URLParam(r, "deviceID")); err != nil {
		redirectMsg(w, r, back, "Device not found (already revoked?).")
		return
	}
	s.log.Info("admin: device revoked", "target", target.Username,
		"by", userFrom(r).Username)
	s.audit(r, "device.revoke", "device", chi.URLParam(r, "deviceID"),
		"device revoked for "+target.Username)
	redirectMsg(w, r, back, "Device revoked — its tokens are dead.")
}

// ---- Catalog ----

func (s *Server) handleCatalog(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	var (
		tracks []store.CatalogTrack
		err    error
	)
	if q == "" {
		tracks, err = s.store.Read().CatalogTracks(ctx)
	} else {
		tracks, err = s.store.Read().SearchCatalog(ctx, q, 200)
	}
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, "Could not list the catalog.")
		return
	}
	s.render(w, "catalog.html", map[string]any{
		"User": userFrom(r), "Active": "catalog",
		"Tracks": tracks, "Query": q, "Msg": r.URL.Query().Get("msg"),
	})
}

func (s *Server) handleCatalogScan(w http.ResponseWriter, r *http.Request) {
	added, pruned, err := s.music.ScanCatalog(r.Context())
	if err != nil {
		redirectMsg(w, r, "/catalog", "Scan failed — check the logs.")
		return
	}
	s.log.Info("admin: catalog scanned", "changed", added, "pruned", pruned,
		"by", userFrom(r).Username)
	s.audit(r, "catalog.scan", "catalog", "",
		fmt.Sprintf("%d changed, %d pruned", added, pruned))
	if added > 0 || pruned > 0 {
		s.changes.Bump("music")
	}
	redirectMsg(w, r, "/catalog",
		fmt.Sprintf("Scan done: %d changed, %d pruned.", added, pruned))
}

// handleCatalogOptimize runs the +faststart pass over the catalog so tracks
// with a trailing moov atom start streaming without a whole-file prefetch.
// Lossless (-c copy) and idempotent — safe to click anytime.
func (s *Server) handleCatalogOptimize(w http.ResponseWriter, r *http.Request) {
	optimized, skipped, err := s.music.OptimizeFaststart(r.Context())
	if err != nil {
		redirectMsg(w, r, "/catalog", "Optimize failed — check the logs.")
		return
	}
	s.log.Info("admin: catalog faststart optimize",
		"optimized", optimized, "skipped", skipped, "by", userFrom(r).Username)
	s.audit(r, "catalog.optimize", "catalog", "",
		fmt.Sprintf("%d optimized, %d already fast", optimized, skipped))
	if optimized > 0 {
		s.changes.Bump("music")
	}
	redirectMsg(w, r, "/catalog",
		fmt.Sprintf("Optimize done: %d re-laid for fast start, %d already fast.",
			optimized, skipped))
}

// maxUpload caps a single multipart request. Music files are a few MB (lossy)
// to ~100MB (lossless); 200MB leaves headroom without inviting abuse.
const maxUpload = 200 << 20

// handleCatalogUpload ingests audio files straight from the admin's browser
// into catalog/music/, then scans so they appear immediately. Multi-file.
func (s *Server) handleCatalogUpload(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxUpload+(4<<20))
	if err := r.ParseMultipartForm(16 << 20); err != nil {
		redirectMsg(w, r, "/catalog",
			"Upload too large or malformed (200MB max per batch).")
		return
	}
	files := r.MultipartForm.File["files"]
	if len(files) == 0 {
		redirectMsg(w, r, "/catalog", "No files chosen.")
		return
	}
	var saved, skipped int
	for _, fh := range files {
		f, err := fh.Open()
		if err != nil {
			skipped++
			continue
		}
		data, err := io.ReadAll(io.LimitReader(f, maxUpload))
		_ = f.Close()
		if err != nil {
			skipped++
			continue
		}
		if _, err := s.music.SaveUpload(fh.Filename, data); err != nil {
			skipped++ // wrong type or write error — reported in the tally
			continue
		}
		saved++
	}
	if saved > 0 {
		if _, _, err := s.music.ScanCatalog(r.Context()); err != nil {
			s.log.Warn("post-upload scan failed", "err", err)
		}
	}
	s.log.Info("admin: catalog upload", "saved", saved, "skipped", skipped,
		"by", userFrom(r).Username)
	s.audit(r, "catalog.upload", "catalog", "",
		fmt.Sprintf("%d uploaded, %d skipped", saved, skipped))
	if saved > 0 {
		s.changes.Bump("music")
	}
	msg := fmt.Sprintf("Uploaded %d file(s).", saved)
	if skipped > 0 {
		msg += fmt.Sprintf(" %d skipped (not audio, or failed).", skipped)
	}
	redirectMsg(w, r, "/catalog", msg)
}

func (s *Server) targetTrack(w http.ResponseWriter, r *http.Request) (*store.CatalogTrack, bool) {
	t, err := s.store.Read().CatalogTrackByID(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		s.renderError(w, http.StatusNotFound, "No such track.")
		return nil, false
	}
	return t, true
}

func (s *Server) handleTrackEditPage(w http.ResponseWriter, r *http.Request) {
	t, ok := s.targetTrack(w, r)
	if !ok {
		return
	}
	s.render(w, "catalog_edit.html", map[string]any{
		"User": userFrom(r), "Active": "catalog",
		"T": t, "Msg": r.URL.Query().Get("msg"),
	})
}

func (s *Server) handleTrackSave(w http.ResponseWriter, r *http.Request) {
	t, ok := s.targetTrack(w, r)
	if !ok {
		return
	}
	back := "/catalog/" + t.ID
	title := strings.TrimSpace(r.FormValue("title"))
	if title == "" {
		redirectMsg(w, r, back, "Title can't be empty.")
		return
	}
	t.Title = title
	t.Artist = strings.TrimSpace(r.FormValue("artist"))
	t.Album = strings.TrimSpace(r.FormValue("album"))
	t.Genre = strings.TrimSpace(r.FormValue("genre"))
	fmt.Sscanf(r.FormValue("track_no"), "%d", &t.TrackNo)
	fmt.Sscanf(r.FormValue("year"), "%d", &t.Year)
	if err := s.store.Write().UpdateCatalogMeta(r.Context(), t.ID, *t); err != nil {
		redirectMsg(w, r, back, "Save failed.")
		return
	}
	s.log.Info("admin: track metadata edited", "track", t.ID,
		"by", userFrom(r).Username)
	s.audit(r, "track.edit", "track", t.ID, "metadata: "+t.Title)
	s.changes.Bump("music")
	redirectMsg(w, r, back, "Saved. Edits survive rescans (DB is authoritative).")
}

func (s *Server) handleTrackDelete(w http.ResponseWriter, r *http.Request) {
	t, ok := s.targetTrack(w, r)
	if !ok {
		return
	}
	// §5: destructive ops need typed confirmation — the exact title.
	if r.FormValue("confirm") != t.Title {
		redirectMsg(w, r, "/catalog/"+t.ID,
			"Type the track's exact title to confirm deletion.")
		return
	}
	if err := s.music.TrashCatalogTrack(r.Context(), t); err != nil {
		redirectMsg(w, r, "/catalog/"+t.ID, "Delete failed — check the logs.")
		return
	}
	s.log.Info("admin: track deleted (trashed)", "track", t.ID,
		"title", t.Title, "by", userFrom(r).Username)
	s.audit(r, "track.delete", "track", t.ID, "trashed: "+t.Title)
	s.changes.Bump("music")
	redirectMsg(w, r, "/catalog",
		"Deleted “"+t.Title+"” — file moved to the catalog trash.")
}

func (s *Server) handleTrackArt(w http.ResponseWriter, r *http.Request) {
	t, ok := s.targetTrack(w, r)
	if !ok {
		return
	}
	// Art version, not file mtime: an uploaded cover override must bust caches.
	etag := fmt.Sprintf(`"%s-%d"`, t.ID, s.music.CatalogArtVersion(t))
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	data, mime, ok2 := s.music.CatalogArtwork(t)
	if !ok2 {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("ETag", etag)
	// no-cache (NOT no-store): the browser must revalidate the ETag on every
	// view, so a just-uploaded cover shows immediately. Unchanged art is still
	// a headers-only 304. max-age made the panel serve day-old art after an
	// upload — the img src has no version param to bust with.
	w.Header().Set("Cache-Control", "private, no-cache")
	_, _ = w.Write(data)
}
