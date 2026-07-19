// Shared movie/show catalog endpoints (M4). Mirrors the music catalog:
// members stream/search on movies:read, only movies:write (admin) mutates.
// New vs music: multi-track media — audio-track selection via zero-CPU remux,
// text subtitles served as WebVTT, and SERVER-side resume (movies are long).
package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// signMovieStreams attaches signed, bearer-free stream URLs (like music).
func (s *Server) signMovieStreams(movies []store.CatalogMovie) {
	if s.signer == nil {
		return
	}
	now := time.Now()
	for i := range movies {
		exp, sig := s.signer.Sign("stream:movie:"+movies[i].ID, now)
		movies[i].StreamURL = "/v1/movies/" + movies[i].ID +
			"/stream?exp=" + exp + "&sig=" + sig
	}
}

// GET /v1/movies?q=  (movies:read) — pure DB read, no scan on listing.
func (s *Server) handleMovies(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	var (
		movies []store.CatalogMovie
		err    error
	)
	if q == "" {
		movies, err = s.store.Read().Movies(r.Context())
	} else {
		movies, err = s.store.Read().SearchMovies(r.Context(), q, 200)
	}
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if movies == nil {
		movies = []store.CatalogMovie{}
	}
	s.signMovieStreams(movies)
	writeJSON(w, http.StatusOK, map[string]any{"movies": movies})
}

// GET /v1/movies/continue  (movies:read) — the Continue Watching shelf.
func (s *Server) handleContinueWatching(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	movies, err := s.store.Read().ContinueWatching(r.Context(), p.UserID, 20)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if movies == nil {
		movies = []store.CatalogMovie{}
	}
	s.signMovieStreams(movies)
	writeJSON(w, http.StatusOK, map[string]any{"movies": movies})
}

// movieFor resolves {id} or writes the error, filling the caller's resume pos.
func (s *Server) movieFor(w http.ResponseWriter, r *http.Request) (*store.CatalogMovie, bool) {
	m, err := s.store.Read().MovieByID(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		s.filesErr(w, r, err)
		return nil, false
	}
	return m, true
}

// GET /v1/movies/{id}  (movies:read) — one title with the caller's resume.
func (s *Server) handleMovieDetail(w http.ResponseWriter, r *http.Request) {
	m, ok := s.movieFor(w, r)
	if !ok {
		return
	}
	p := PrincipalFrom(r.Context())
	m.ResumeMs, _ = s.store.Read().ResumeFor(r.Context(), p.UserID, m.ID)
	s.signMovieStreams([]store.CatalogMovie{*m})
	// signMovieStreams took a copy; re-sign this pointer.
	if s.signer != nil {
		exp, sig := s.signer.Sign("stream:movie:"+m.ID, time.Now())
		m.StreamURL = "/v1/movies/" + m.ID + "/stream?exp=" + exp + "&sig=" + sig
	}
	writeJSON(w, http.StatusOK, m)
}

// GET /v1/movies/{id}/stream  (signed or movies:read)
// Default/single audio → direct file serve (Range/seek, no ffmpeg). A non-
// default `?audio=N` selects that track via zero-CPU remux; `?start=SEC`
// fast-seeks (a remuxed pipe can't serve Range).
func (s *Server) handleMovieStream(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	id := chi.URLParam(r, "id")
	q := r.URL.Query()

	// Auth: signed URL OR bearer + grant, same as music.
	if sig := q.Get("sig"); sig != "" && s.signer != nil {
		if !s.signer.Verify("stream:movie:"+id, q.Get("exp"), sig, time.Now()) {
			writeErr(w, http.StatusUnauthorized, "invalid or expired stream URL")
			return
		}
	} else {
		p := s.bearerPrincipal(r)
		if p == nil {
			writeErr(w, http.StatusUnauthorized, "missing or invalid token")
			return
		}
		if !s.hasGrant(r, p, "movies", "read") {
			writeErr(w, http.StatusForbidden, "movies access not granted")
			return
		}
	}

	m, err := s.store.Read().MovieByID(ctx, id)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	path := s.movies.MoviePath(m)

	audio, _ := strconv.Atoi(q.Get("audio"))
	start, _ := strconv.Atoi(q.Get("start"))
	// audio<=0 with no start = the default track: serve the file directly, so
	// AVPlayer gets full Range seeking. Only a non-default pick needs remux.
	if audio <= 0 && start == 0 {
		http.ServeFile(w, r, path)
		return
	}
	w.Header().Set("Content-Type", "video/mp4")
	w.WriteHeader(http.StatusOK)
	if err := s.movies.RemuxAudio(ctx, path, audio, start, w); err != nil {
		s.log.Warn("remux stream failed", "id", id, "audio", audio, "err", err)
	}
}

// GET /v1/movies/{id}/subs/{track}.vtt  (movies:read) — a subtitle track as
// WebVTT. `track` is "e<N>" for an embedded stream or "x<N>" for the Nth
// sidecar, matching the client's stream list order.
func (s *Server) handleMovieSubs(w http.ResponseWriter, r *http.Request) {
	m, ok := s.movieFor(w, r)
	if !ok {
		return
	}
	track := strings.TrimSuffix(chi.URLParam(r, "track"), ".vtt")
	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.Header().Set("Cache-Control", "private, max-age=86400")

	ctx := r.Context()
	if strings.HasPrefix(track, "x") { // sidecar
		idx, _ := strconv.Atoi(track[1:])
		sidecars := externalSubs(m.Streams.Subs)
		if idx < 0 || idx >= len(sidecars) {
			writeErr(w, http.StatusNotFound, "no such subtitle")
			return
		}
		p := s.movies.SidecarSubPath(sidecars[idx].External)
		if err := s.movies.ConvertSidecarVTT(ctx, p, w); err != nil {
			s.log.Warn("sidecar vtt failed", "err", err)
		}
		return
	}
	// embedded: "e<N>"
	idx, _ := strconv.Atoi(strings.TrimPrefix(track, "e"))
	if err := s.movies.ExtractSubVTT(ctx, s.movies.MoviePath(m), idx, w); err != nil {
		s.log.Warn("embedded vtt failed", "err", err)
	}
}

func externalSubs(subs []store.SubStream) []store.SubStream {
	var out []store.SubStream
	for _, x := range subs {
		if x.External != "" {
			out = append(out, x)
		}
	}
	return out
}

// GET /v1/movies/{id}/art  (movies:read) — poster, ETag'd.
func (s *Server) handleMovieArt(w http.ResponseWriter, r *http.Request) {
	m, ok := s.movieFor(w, r)
	if !ok {
		return
	}
	etag := fmt.Sprintf(`"%s-%d"`, m.ID, s.movies.ArtVersion(m))
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	data, mime, ok2 := s.movies.Artwork(m)
	if !ok2 {
		writeErr(w, http.StatusNotFound, "no artwork")
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, _ = w.Write(data)
}

// POST /v1/movies/{id}/watches {position_ms, duration_ms}  (movies:read)
// Fire-and-forget resume tracking; server keeps the latest position.
func (s *Server) handleRecordWatch(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PositionMs int64 `json:"position_ms"`
		DurationMs int64 `json:"duration_ms"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	p := PrincipalFrom(r.Context())
	id := chi.URLParam(r, "id")
	if err := s.store.Write().RecordWatch(r.Context(), p.UserID, id,
		req.PositionMs, req.DurationMs); err != nil {
		writeErr(w, http.StatusBadRequest, "unknown movie")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// PATCH /v1/movies/{id}  (movies:write) — admin metadata edit.
func (s *Server) handleMovieEdit(w http.ResponseWriter, r *http.Request) {
	m, ok := s.movieFor(w, r)
	if !ok {
		return
	}
	patch := struct {
		Title    *string `json:"title"`
		Year     *int    `json:"year"`
		Series   *string `json:"series"`
		Season   *int    `json:"season"`
		Episode  *int    `json:"episode"`
		Overview *string `json:"overview"`
	}{}
	if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	if patch.Title != nil {
		m.Title = strings.TrimSpace(*patch.Title)
	}
	if patch.Series != nil {
		m.Series = strings.TrimSpace(*patch.Series)
	}
	if patch.Overview != nil {
		m.Overview = strings.TrimSpace(*patch.Overview)
	}
	if patch.Year != nil {
		m.Year = *patch.Year
	}
	if patch.Season != nil {
		m.Season = *patch.Season
	}
	if patch.Episode != nil {
		m.Episode = *patch.Episode
	}
	if m.Title == "" {
		writeErr(w, http.StatusBadRequest, "title required")
		return
	}
	if err := s.store.Write().UpdateMovieMeta(r.Context(), m.ID, *m); err != nil {
		s.filesErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, m)
}

// POST /v1/movies/scan  (movies:write)
func (s *Server) handleMovieScan(w http.ResponseWriter, r *http.Request) {
	changed, pruned, err := s.movies.Scan(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"changed": changed, "pruned": pruned})
}
