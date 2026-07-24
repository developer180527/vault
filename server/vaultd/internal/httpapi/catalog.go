// Shared music catalog endpoints: the admin-curated library every authorized
// member streams from, plus per-user playlists (track UUID + owner UUID) and
// the append-only listen log that future recommenders train on. Additive to
// /v1 — the per-user /v1/music/tracks endpoints are untouched.
package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// GET /v1/music/catalog?q=  (music:read)
// Pure DB read — no scan on listing. The catalog only changes when the admin
// loads music and triggers a scan, so listings stay O(query) at any size.
func (s *Server) handleCatalog(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	var (
		tracks []store.CatalogTrack
		err    error
	)
	if q == "" {
		tracks, err = s.store.Read().CatalogTracks(r.Context())
	} else {
		tracks, err = s.store.Read().SearchCatalog(r.Context(), q, 200)
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if tracks == nil {
		tracks = []store.CatalogTrack{}
	}
	s.signCatalogStreams(tracks)
	writeJSON(w, http.StatusOK, map[string]any{"tracks": tracks})
}

// catalogTrackFor resolves {id} or writes the error.
func (s *Server) catalogTrackFor(w http.ResponseWriter, r *http.Request) (*store.CatalogTrack, bool) {
	t, err := s.store.Read().CatalogTrackByID(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		s.filesErr(w, r, err)
		return nil, false
	}
	return t, true
}

// GET /v1/music/catalog/{id}/stream — Range/seek via ServeFile. Outside the
// auth middleware: signed URL (sig/exp) OR bearer + music:read, same rationale
// as the per-user stream.
func (s *Server) handleCatalogStream(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := chi.URLParam(r, "id")
	q := r.URL.Query()

	// Accept a valid signed URL OR a bearer with music:read. A stale/expired
	// signature (e.g. a >24h cached listing) falls THROUGH to the bearer that
	// the client still attaches — 401 only when NEITHER proof holds. Without
	// this fallthrough, a cached listing silently stopped streaming after a day.
	authed := q.Get("sig") != "" && s.signer != nil &&
		s.signer.Verify("stream:catalog:"+id, q.Get("exp"), q.Get("sig"), time.Now())
	if !authed {
		p := s.bearerPrincipal(r)
		if p == nil || !s.hasGrant(r, p, "music", "read") {
			writeErr(w, http.StatusUnauthorized,
				"stream needs a valid signed URL or an authorized token")
			return
		}
	}
	// Hottest tracks are served from RAM (Range from memory, no disk I/O);
	// a miss falls through to the file. The warm path needs no DB row.
	if s.music.ServeWarm(w, r, id) {
		return
	}
	t, err := s.store.Read().CatalogTrackByID(ctx, id)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	http.ServeFile(w, r, s.music.CatalogTrackPath(t))
}

// GET /v1/music/catalog/{id}/art  (music:read) — lazy parse, ETag'd.
func (s *Server) handleCatalogArt(w http.ResponseWriter, r *http.Request) {
	t, ok := s.catalogTrackFor(w, r)
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
		writeErr(w, http.StatusNotFound, "no artwork")
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, _ = w.Write(data)
}

// PATCH /v1/music/catalog/{id}  (music:write — admin metadata edit)
// The DB is authoritative: edits made here survive rescans by design.
func (s *Server) handleCatalogEdit(w http.ResponseWriter, r *http.Request) {
	t, ok := s.catalogTrackFor(w, r)
	if !ok {
		return
	}
	// Start from current values so a partial body only changes what it sends.
	patch := struct {
		Title   *string `json:"title"`
		Artist  *string `json:"artist"`
		Album   *string `json:"album"`
		Genre   *string `json:"genre"`
		TrackNo *int    `json:"track_no"`
		Year    *int    `json:"year"`
	}{}
	if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	apply := func(dst *string, v *string) {
		if v != nil {
			*dst = strings.TrimSpace(*v)
		}
	}
	apply(&t.Title, patch.Title)
	apply(&t.Artist, patch.Artist)
	apply(&t.Album, patch.Album)
	apply(&t.Genre, patch.Genre)
	if patch.TrackNo != nil {
		t.TrackNo = *patch.TrackNo
	}
	if patch.Year != nil {
		t.Year = *patch.Year
	}
	if t.Title == "" {
		writeErr(w, http.StatusBadRequest, "title required")
		return
	}
	if err := s.store.Write().UpdateCatalogMeta(r.Context(), t.ID, *t); err != nil {
		s.filesErr(w, r, err)
		return
	}
	s.changes.Bump("music")
	writeJSON(w, http.StatusOK, t)
}

// POST /v1/music/catalog/scan  (music:write — admin loads files, then this)
func (s *Server) handleCatalogScan(w http.ResponseWriter, r *http.Request) {
	changed, pruned, err := s.music.ScanCatalog(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if changed > 0 || pruned > 0 {
		s.changes.Bump("music")
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"changed": changed, "pruned": pruned,
	})
}

// POST /v1/music/catalog/optimize  (music:write) — one-shot +faststart pass:
// rewrites catalog tracks with a trailing moov atom (lossless -c copy) so
// playback starts without fetching the whole file. Idempotent.
func (s *Server) handleCatalogOptimize(w http.ResponseWriter, r *http.Request) {
	optimized, skipped, err := s.music.OptimizeFaststart(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if optimized > 0 {
		s.changes.Bump("music")
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"optimized": optimized, "skipped": skipped,
	})
}

// --- playlists ---

// GET /v1/music/playlists  (music:read) — caller's playlists only.
func (s *Server) handleListPlaylists(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	lists, err := s.store.Read().PlaylistsForUser(r.Context(), p.UserID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if lists == nil {
		lists = []store.Playlist{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"playlists": lists})
}

// POST /v1/music/playlists {name}  (music:read)
func (s *Server) handleCreatePlaylist(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		strings.TrimSpace(req.Name) == "" {
		writeErr(w, http.StatusBadRequest, "name required")
		return
	}
	p := PrincipalFrom(r.Context())
	pl, err := s.store.Write().CreatePlaylist(r.Context(), p.UserID, strings.TrimSpace(req.Name))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, pl)
}

// DELETE /v1/music/playlists/{id}  (music:read, owner-scoped in the store)
func (s *Server) handleDeletePlaylist(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	if err := s.store.Write().DeletePlaylist(r.Context(), p.UserID, chi.URLParam(r, "id")); err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// GET /v1/music/playlists/{id}/tracks  (music:read)
func (s *Server) handlePlaylistTracks(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	tracks, err := s.store.Read().PlaylistTracks(r.Context(), p.UserID, chi.URLParam(r, "id"))
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	if tracks == nil {
		tracks = []store.CatalogTrack{}
	}
	s.signCatalogStreams(tracks)
	writeJSON(w, http.StatusOK, map[string]any{"tracks": tracks})
}

// POST /v1/music/playlists/{id}/tracks {track_id}  (music:read)
func (s *Server) handleAddToPlaylist(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TrackID string `json:"track_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.TrackID == "" {
		writeErr(w, http.StatusBadRequest, "track_id required")
		return
	}
	// Validate the track exists so playlists can't hold dangling ids.
	if _, err := s.store.Read().CatalogTrackByID(r.Context(), req.TrackID); err != nil {
		s.filesErr(w, r, err)
		return
	}
	p := PrincipalFrom(r.Context())
	if err := s.store.Write().AddToPlaylist(r.Context(), p.UserID, chi.URLParam(r, "id"), req.TrackID); err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// DELETE /v1/music/playlists/{id}/tracks/{trackId}  (music:read)
func (s *Server) handleRemoveFromPlaylist(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	err := s.store.Write().RemoveFromPlaylist(r.Context(), p.UserID,
		chi.URLParam(r, "id"), chi.URLParam(r, "trackId"))
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// --- listens (ML event log) ---

// POST /v1/music/listens {track_id, source, ms_played?}  (music:read)
// Fire-and-forget from the client's playback controller: raw facts only,
// aggregates are the recommender's job.
func (s *Server) handleReportListen(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TrackID  string `json:"track_id"`
		Source   string `json:"source"`
		MsPlayed int    `json:"ms_played"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.TrackID == "" {
		writeErr(w, http.StatusBadRequest, "track_id required")
		return
	}
	if req.MsPlayed < 0 {
		req.MsPlayed = 0
	}
	p := PrincipalFrom(r.Context())
	if err := s.store.Write().InsertListen(r.Context(), p.UserID, req.TrackID, req.MsPlayed, req.Source); err != nil {
		// FK failure = unknown track id: client bug or a pruned track.
		writeErr(w, http.StatusBadRequest, "unknown track")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"ok": true})
}

// GET /v1/music/you/most-played  (music:read)
// The "You" shelf: this caller's top catalog tracks by total play time. Empty
// until they've listened to something — a fresh account has no history.
func (s *Server) handleMostPlayed(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	tracks, err := s.store.Read().MostPlayed(r.Context(), p.UserID, 25)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if tracks == nil {
		tracks = []store.CatalogTrack{}
	}
	s.signCatalogStreams(tracks)
	writeJSON(w, http.StatusOK, map[string]any{"tracks": tracks})
}

// --- favorites (per-user liked songs) ---

// GET /v1/music/favorites  (music:read) — caller's liked tracks, newest first.
func (s *Server) handleListFavorites(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	tracks, err := s.store.Read().Favorites(r.Context(), p.UserID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if tracks == nil {
		tracks = []store.CatalogTrack{}
	}
	s.signCatalogStreams(tracks)
	writeJSON(w, http.StatusOK, map[string]any{"tracks": tracks})
}

// PUT /v1/music/favorites/{id}  (music:read) — like a catalog track.
func (s *Server) handleAddFavorite(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	// Validate the track exists so favorites can't hold dangling ids.
	if _, err := s.store.Read().CatalogTrackByID(r.Context(), id); err != nil {
		s.filesErr(w, r, err)
		return
	}
	p := PrincipalFrom(r.Context())
	if err := s.store.Write().AddFavorite(r.Context(), p.UserID, id); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// DELETE /v1/music/favorites/{id}  (music:read) — unlike a track.
func (s *Server) handleRemoveFavorite(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	if err := s.store.Write().RemoveFavorite(r.Context(), p.UserID, chi.URLParam(r, "id")); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
