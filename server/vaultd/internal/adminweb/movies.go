// Movie catalog manager (admin panel). Mirrors the music catalog manager, but
// there's no browser upload: movie files are large, so the flow is copy to the
// server (scp/rsync into /srv/vault/movies) then Scan. Per-title metadata
// editing, poster override, and trash-delete match music.
package adminweb

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/store"
)

func (s *Server) handleMovieCatalog(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	var (
		movies []store.CatalogMovie
		err    error
	)
	if q == "" {
		movies, err = s.store.Read().Movies(ctx)
	} else {
		movies, err = s.store.Read().SearchMovies(ctx, q, 200)
	}
	if err != nil {
		s.renderError(w, http.StatusInternalServerError, "Could not list the movie catalog.")
		return
	}
	s.render(w, "movies.html", map[string]any{
		"User": userFrom(r), "Active": "movies",
		"Movies": movies, "Query": q, "Msg": r.URL.Query().Get("msg"),
	})
}

func (s *Server) handleMovieCatalogScan(w http.ResponseWriter, r *http.Request) {
	added, pruned, err := s.movies.Scan(r.Context())
	if err != nil {
		redirectMsg(w, r, "/movies", "Scan failed — check the logs.")
		return
	}
	s.log.Info("admin: movie catalog scanned", "changed", added, "pruned", pruned,
		"by", userFrom(r).Username)
	s.audit(r, "movies.scan", "movies", "",
		fmt.Sprintf("%d changed, %d pruned", added, pruned))
	redirectMsg(w, r, "/movies",
		fmt.Sprintf("Scan done: %d changed, %d pruned.", added, pruned))
}

// maxMovieUpload caps a single browser upload. Big enough for a 1080p feature
// or a season pack; genuinely huge libraries still want scp/rsync + Scan.
const maxMovieUpload = 8 << 30 // 8 GiB

// handleMovieUpload streams uploaded video files straight to the catalog (no
// buffering — they're gigabytes), then scans so they appear immediately.
// Multi-file. The browser has no progress bar (zero-JS panel); the tally is
// reported on redirect.
func (s *Server) handleMovieUpload(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxMovieUpload+(8<<20))
	mr, err := r.MultipartReader()
	if err != nil {
		redirectMsg(w, r, "/movies", "Upload malformed or too large (8GB max).")
		return
	}
	var saved, skipped int
	for {
		part, err := mr.NextPart()
		if err != nil {
			break // end of parts
		}
		if part.FormName() != "files" || part.FileName() == "" {
			continue
		}
		if _, err := s.movies.SaveUploadStream(part.FileName(), part); err != nil {
			s.log.Warn("movie upload part failed", "name", part.FileName(), "err", err)
			skipped++
			continue
		}
		saved++
	}
	if saved > 0 {
		if _, _, err := s.movies.Scan(r.Context()); err != nil {
			s.log.Warn("post-upload movie scan failed", "err", err)
		}
	}
	s.log.Info("admin: movie upload", "saved", saved, "skipped", skipped,
		"by", userFrom(r).Username)
	s.audit(r, "movies.upload", "movies", "",
		fmt.Sprintf("%d uploaded, %d skipped", saved, skipped))
	msg := fmt.Sprintf("Uploaded %d file(s).", saved)
	if skipped > 0 {
		msg += fmt.Sprintf(" %d skipped (not video, or failed).", skipped)
	}
	redirectMsg(w, r, "/movies", msg)
}

func (s *Server) targetMovie(w http.ResponseWriter, r *http.Request) (*store.CatalogMovie, bool) {
	m, err := s.store.Read().MovieByID(r.Context(), chi.URLParam(r, "id"))
	if err != nil {
		s.renderError(w, http.StatusNotFound, "No such title.")
		return nil, false
	}
	return m, true
}

func (s *Server) handleMovieEditPage(w http.ResponseWriter, r *http.Request) {
	m, ok := s.targetMovie(w, r)
	if !ok {
		return
	}
	s.render(w, "movie_edit.html", map[string]any{
		"User": userFrom(r), "Active": "movies",
		"M": m, "Msg": r.URL.Query().Get("msg"),
	})
}

func (s *Server) handleMovieSave(w http.ResponseWriter, r *http.Request) {
	m, ok := s.targetMovie(w, r)
	if !ok {
		return
	}
	back := "/movies/" + m.ID
	title := strings.TrimSpace(r.FormValue("title"))
	if title == "" {
		redirectMsg(w, r, back, "Title can't be empty.")
		return
	}
	m.Title = title
	m.Series = strings.TrimSpace(r.FormValue("series"))
	m.Overview = strings.TrimSpace(r.FormValue("overview"))
	m.Kind = "movie"
	if strings.TrimSpace(r.FormValue("kind")) == "episode" {
		m.Kind = "episode"
	}
	m.Year = atoiField(r, "year")
	m.Season = atoiField(r, "season")
	m.Episode = atoiField(r, "episode")
	if err := s.store.Write().UpdateMovieMeta(r.Context(), m.ID, *m); err != nil {
		redirectMsg(w, r, back, "Save failed.")
		return
	}
	s.log.Info("admin: movie metadata edited", "movie", m.ID,
		"by", userFrom(r).Username)
	s.audit(r, "movie.edit", "movie", m.ID, "metadata: "+m.Title)
	redirectMsg(w, r, back, "Saved. Edits survive rescans (DB is authoritative).")
}

func (s *Server) handleMovieDelete(w http.ResponseWriter, r *http.Request) {
	m, ok := s.targetMovie(w, r)
	if !ok {
		return
	}
	if r.FormValue("confirm") != m.Title {
		redirectMsg(w, r, "/movies/"+m.ID,
			"Type the title's exact name to confirm deletion.")
		return
	}
	if err := s.movies.Trash(r.Context(), m); err != nil {
		redirectMsg(w, r, "/movies/"+m.ID, "Delete failed — check the logs.")
		return
	}
	s.log.Info("admin: movie deleted (trashed)", "movie", m.ID,
		"title", m.Title, "by", userFrom(r).Username)
	s.audit(r, "movie.delete", "movie", m.ID, "trashed: "+m.Title)
	redirectMsg(w, r, "/movies",
		"Deleted “"+m.Title+"” — file moved to the catalog trash.")
}

func (s *Server) handleMoviePoster(w http.ResponseWriter, r *http.Request) {
	m, ok := s.targetMovie(w, r)
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
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, _ = w.Write(data)
}

func (s *Server) handleMoviePosterUpload(w http.ResponseWriter, r *http.Request) {
	m, ok := s.targetMovie(w, r)
	if !ok {
		return
	}
	back := "/movies/" + m.ID
	file, _, err := r.FormFile("art")
	if err != nil {
		redirectMsg(w, r, back, "No image chosen.")
		return
	}
	defer file.Close()
	data := make([]byte, 0, artMaxBytes)
	buf := make([]byte, 32<<10)
	for len(data) <= artMaxBytes {
		n, rerr := file.Read(buf)
		data = append(data, buf[:n]...)
		if rerr != nil {
			break
		}
	}
	if len(data) == 0 || len(data) > artMaxBytes {
		redirectMsg(w, r, back, "Image too large (10MB max) or empty.")
		return
	}
	if !strings.HasPrefix(http.DetectContentType(data), "image/") {
		redirectMsg(w, r, back, "That file isn’t an image.")
		return
	}
	if err := s.movies.SetArtOverride(m.ID, data); err != nil {
		redirectMsg(w, r, back, "Couldn’t save the poster.")
		return
	}
	s.log.Info("admin: movie poster set", "movie", m.ID, "by", userFrom(r).Username)
	s.audit(r, "movie.art", "movie", m.ID, "poster: "+m.Title)
	redirectMsg(w, r, back, "Poster updated — shows everywhere, survives rescans.")
}

func atoiField(r *http.Request, name string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(r.FormValue(name)))
	return n
}
