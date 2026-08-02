// Media info for arbitrary files (docs/MOVIES.md "any service"). Movies are
// probed at scan and carry their streams on the row; every OTHER video — one
// sitting in a user's Files zone, say — has to be probed on demand.
//
// This is what lets the audio-track picker work for a video from ANY service:
// the player asks "what's in this?", gets the same stream descriptor shape the
// movie catalog returns, and asks for a track with the same ?audio=N param.
package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/files"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// mediaInfo is the wire shape, deliberately identical to the movie catalog's
// so one client model parses both.
type mediaInfo struct {
	Container  string             `json:"container"`
	VCodec     string             `json:"vcodec"`
	Width      int                `json:"width"`
	Height     int                `json:"height"`
	DurationMs int64              `json:"duration_ms"`
	Streams    store.MovieStreams `json:"streams"`
}

// fileAbsPath resolves {id} to an absolute path plus its stat, owner-scoped.
func (s *Server) fileAbsPath(r *http.Request) (abs string, fi os.FileInfo, username, rel string, err error) {
	rel, err = files.DecodeID(chi.URLParam(r, "id"))
	if err != nil {
		return "", nil, "", "", err
	}
	username, err = s.username(r)
	if err != nil {
		return "", nil, "", "", err
	}
	abs, err = s.files.SafeJoin(username, rel)
	if err != nil {
		return "", nil, "", "", err
	}
	fi, err = os.Stat(abs)
	return abs, fi, username, rel, err
}

// GET /v1/files/{id}/mediainfo  (files:read)
// Probe result for one file, cached by (user, path, size, mtime).
func (s *Server) handleFileMediaInfo(w http.ResponseWriter, r *http.Request) {
	abs, fi, username, rel, err := s.fileAbsPath(r)
	if err != nil {
		s.filesErr(w, r, err)
		return
	}
	key := fmt.Sprintf("%s|%s|%d|%d", username, rel, fi.Size(), fi.ModTime().Unix())

	// Cache hit: hand back the stored JSON verbatim.
	if cached, err := s.store.Read().MediaProbe(r.Context(), key); err == nil {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "private, max-age=3600")
		_, _ = w.Write([]byte(cached))
		return
	}

	info := mediaInfo{}
	// Prober is nil only in tests that don't exercise probing; answer with an
	// empty descriptor rather than failing the request.
	if s.movies != nil && s.movies.Prober != nil {
		pr, perr := s.movies.Prober.Probe(abs)
		if perr != nil {
			// Not probeable (not media, or ffprobe missing) — an empty
			// descriptor is the honest answer, and it's cacheable.
			s.log.Debug("mediainfo probe failed", "rel", rel, "err", perr)
		} else {
			info = mediaInfo{
				VCodec:     pr.VCodec,
				Width:      pr.Width,
				Height:     pr.Height,
				DurationMs: pr.DurationMs,
				Streams: store.MovieStreams{
					Audio: pr.Audio,
					Subs:  pr.Subs,
				},
			}
		}
	}
	blob, err := json.Marshal(info)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if err := s.store.Write().PutMediaProbe(r.Context(), key, string(blob)); err != nil {
		s.log.Warn("mediainfo cache write failed", "err", err)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	_, _ = w.Write(blob)
}

// fileStreamVariant handles ?audio=N / ?start=S on file content: a non-default
// audio track (or a seek into a remuxed pipe) goes through the same zero-CPU
// `-c copy` rewrite the movie catalog uses. Reports whether it handled the
// request; false means "serve the raw file".
//
// The ffmpeg primitives live on the movies service but take a plain path —
// they were always generic, so Files reuses them rather than duplicating the
// invocation logic.
func (s *Server) fileStreamVariant(w http.ResponseWriter, r *http.Request, abs string) bool {
	q := r.URL.Query()
	audio, _ := strconv.Atoi(q.Get("audio"))
	start, _ := strconv.Atoi(q.Get("start"))
	if audio <= 0 && start <= 0 {
		return false
	}
	if audio < 0 {
		audio = 0
	}
	if start < 0 {
		start = 0
	}
	w.Header().Set("Content-Type", "video/mp4")
	if err := s.movies.RemuxAudio(r.Context(), abs, audio, start, w); err != nil {
		s.log.Warn("file remux failed", "audio", audio, "err", err)
	}
	return true
}
