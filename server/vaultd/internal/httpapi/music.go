package httpapi

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/store"
)

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
func (s *Server) handleStreamTrack(w http.ResponseWriter, r *http.Request) {
	t, ok := s.trackFor(w, r)
	if !ok {
		return
	}
	p := PrincipalFrom(r.Context())
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
