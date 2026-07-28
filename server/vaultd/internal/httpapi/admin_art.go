package httpapi

import (
	"io"
	"net/http"
	"strings"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// Artwork upload for the Administrative service. The admin panel has had this
// as an HTML form; these are the app-facing equivalents — a raw image body
// rather than multipart, since the client already holds the bytes.
//
//	PUT /v1/admin/catalog/{id}/art   — music cover
//	PUT /v1/admin/movies/{id}/art    — movie poster
//
// Both store an OVERRIDE beside the media (never rewriting the file's own
// tags), which is why this needs no ffmpeg and can't corrupt a library file.

// artMaxUpload caps a cover/poster. Art is a few hundred KB; 10 MiB is
// generous and keeps a bad request from eating memory.
const artMaxUpload = 10 << 20

// readImageBody reads an image body, verifying it really is an image. Returns
// false (after writing the error) when the body is unusable.
func (s *Server) readImageBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, artMaxUpload))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "image too large (10 MB max)")
		return nil, false
	}
	if len(data) == 0 {
		writeErr(w, http.StatusBadRequest, "empty body")
		return nil, false
	}
	// Sniff the CONTENT, not the client's claim — a mislabelled or hostile
	// upload must not land in the library as "art".
	if !strings.HasPrefix(http.DetectContentType(data), "image/") {
		writeErr(w, http.StatusUnsupportedMediaType, "not an image")
		return nil, false
	}
	return data, true
}

// PUT /v1/admin/catalog/{id}/art — replace a track's cover.
func (s *Server) handleAdminSetTrackArt(w http.ResponseWriter, r *http.Request) {
	t, ok := s.catalogTrackFor(w, r)
	if !ok {
		return
	}
	data, ok := s.readImageBody(w, r)
	if !ok {
		return
	}
	if err := s.music.SetCatalogArtOverride(t.ID, data); err != nil {
		s.fail(w, r, err)
		return
	}
	// Flip has_art: the client deliberately SKIPS art fetches when the flag is
	// false, so without this an uploaded cover is never even requested.
	if !t.HasArt {
		if err := s.store.Write().SetCatalogHasArt(r.Context(), t.ID, true); err != nil {
			s.log.Warn("set has_art failed", "id", t.ID, "err", err)
		}
	}
	p := PrincipalFrom(r.Context())
	s.log.Info("track art set", "id", t.ID, "by", p.Username, "bytes", len(data))
	s.audit(r, "track.art", "track", t.ID, "cover art replaced: "+t.Title)
	// art_version is the override's mtime, so this bump makes every client
	// re-list, see a new version, and cache-bust the cover URL.
	s.changes.Bump("music")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// PUT /v1/admin/movies/{id}/art — replace a movie's poster.
func (s *Server) handleAdminSetMovieArt(w http.ResponseWriter, r *http.Request) {
	m, ok := s.movieFor(w, r)
	if !ok {
		return
	}
	data, ok := s.readImageBody(w, r)
	if !ok {
		return
	}
	if err := s.movies.SetArtOverride(m.ID, data); err != nil {
		s.fail(w, r, err)
		return
	}
	if !m.HasArt {
		if err := s.store.Write().SetMovieArt(r.Context(), m.ID, true); err != nil {
			s.log.Warn("set movie has_art failed", "id", m.ID, "err", err)
		}
	}
	p := PrincipalFrom(r.Context())
	s.log.Info("movie art set", "id", m.ID, "by", p.Username, "bytes", len(data))
	s.audit(r, "movie.art", "movie", m.ID, "poster replaced: "+m.Title)
	s.changes.Bump("movies")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// audit appends one activity row. Best-effort BY DESIGN: the mutation already
// happened, so a failed audit write is logged, never surfaced as a failure.
func (s *Server) audit(r *http.Request, action, kind, id, summary string) {
	p := PrincipalFrom(r.Context())
	if err := s.store.Write().InsertAudit(r.Context(), store.AuditEntry{
		ActorUser:  p.Username,
		Action:     action,
		TargetKind: kind,
		TargetID:   id,
		Summary:    summary,
		RemoteAddr: r.RemoteAddr,
	}); err != nil {
		s.log.Error("audit write failed", "action", action, "err", err)
	}
}
