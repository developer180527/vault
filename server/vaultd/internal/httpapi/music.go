package httpapi

import (
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// signUserStreams attaches signed, bearer-free stream URLs to a user's tracks
// so playback outlives the 15-minute access token (loop restarts, queue
// wraps, late seeks — docs/MUSIC.md "signed stream URLs").
func (s *Server) signUserStreams(username string, tracks []store.Track) {
	if s.signer == nil {
		return
	}
	now := time.Now()
	for i := range tracks {
		exp, sig := s.signer.Sign(
			"stream:user:"+username+":"+tracks[i].ID, now)
		tracks[i].StreamURL = "/v1/music/tracks/" + tracks[i].ID +
			"/stream?u=" + url.QueryEscape(username) + "&exp=" + exp + "&sig=" + sig
	}
}

// signCatalogStreams: same, for shared-catalog tracks.
func (s *Server) signCatalogStreams(tracks []store.CatalogTrack) {
	if s.signer == nil {
		return
	}
	now := time.Now()
	for i := range tracks {
		exp, sig := s.signer.Sign("stream:catalog:"+tracks[i].ID, now)
		tracks[i].StreamURL = "/v1/music/catalog/" + tracks[i].ID +
			"/stream?exp=" + exp + "&sig=" + sig
	}
}

// GET /v1/music/tracks — incremental scan, then the full library. The scan on
// every listing is what keeps the index truthful without a watcher daemon
// (docs/MUSIC.md); it's a stat-walk when nothing changed.
func (s *Server) handleListTracks(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	if err := s.music.Scan(r.Context(), p.UserID, p.Username); err != nil {
		s.fail(w, r, err)
		return
	}
	tracks, err := s.store.Read().TracksForUser(r.Context(), p.UserID)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.signUserStreams(p.Username, tracks)
	writeJSON(w, http.StatusOK, map[string]any{"tracks": tracks})
}

// GET /v1/music/search?q= — FTS5 prefix match over title/artist/album.
func (s *Server) handleSearchTracks(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeJSON(w, http.StatusOK, map[string]any{"tracks": []store.Track{}})
		return
	}
	p := PrincipalFrom(r.Context())
	tracks, err := s.store.Read().SearchTracks(r.Context(), p.UserID, q, 100)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if tracks == nil {
		tracks = []store.Track{}
	}
	s.signUserStreams(p.Username, tracks)
	writeJSON(w, http.StatusOK, map[string]any{"tracks": tracks})
}

// trackFor resolves {id} to the caller's track or writes the error.
func (s *Server) trackFor(w http.ResponseWriter, r *http.Request) (*store.Track, bool) {
	p := PrincipalFrom(r.Context())
	t, err := s.store.Read().TrackByID(r.Context(), p.UserID, chi.URLParam(r, "id"))
	if err != nil {
		s.filesErr(w, r, err) // maps ErrNotFound → 404
		return nil, false
	}
	return t, true
}

// GET /v1/music/tracks/{id}/stream — bytes with Range/seek via ServeFile.
// Sits OUTSIDE the auth middleware: accepts a signed URL (sig/exp/u query)
// OR a live bearer + music:read. Signed URLs are what let playback outlive
// the 15-minute token.
func (s *Server) handleStreamTrack(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := chi.URLParam(r, "id")
	q := r.URL.Query()

	if sig := q.Get("sig"); sig != "" && s.signer != nil {
		username := q.Get("u")
		if !s.signer.Verify(
			"stream:user:"+username+":"+id, q.Get("exp"), sig, time.Now()) {
			writeErr(w, http.StatusUnauthorized, "invalid or expired stream URL")
			return
		}
		user, err := s.store.Read().UserByUsername(ctx, username)
		if err != nil {
			writeErr(w, http.StatusNotFound, "not found")
			return
		}
		t, err := s.store.Read().TrackByID(ctx, user.ID, id)
		if err != nil {
			s.filesErr(w, r, err)
			return
		}
		http.ServeFile(w, r, s.music.TrackPath(username, t))
		return
	}

	// Bearer path — same checks the middleware chain used to make.
	p := s.bearerPrincipal(r)
	if p == nil {
		writeErr(w, http.StatusUnauthorized, "missing or invalid token")
		return
	}
	if !s.hasGrant(r, p, "music", "read") {
		writeErr(w, http.StatusForbidden, "music access not granted")
		return
	}
	t, err := s.store.Read().TrackByID(ctx, p.UserID, id)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	http.ServeFile(w, r, s.music.TrackPath(p.Username, t))
}

// GET /v1/music/tracks/{id}/art — embedded artwork, lazily parsed, ETag'd so
// repeat fetches are 304s (art is never duplicated into the DB).
func (s *Server) handleTrackArt(w http.ResponseWriter, r *http.Request) {
	t, ok := s.trackFor(w, r)
	if !ok {
		return
	}
	etag := fmt.Sprintf(`"%s-%d"`, t.ID, t.Mtime)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	p := PrincipalFrom(r.Context())
	data, mime, ok2 := s.music.Artwork(p.Username, t)
	if !ok2 {
		writeErr(w, http.StatusNotFound, "no artwork")
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, _ = w.Write(data)
}
