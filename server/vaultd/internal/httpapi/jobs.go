package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// jobJSON is the wire shape the client's VaultJob parses.
func jobJSON(j store.Job) map[string]any {
	return map[string]any{
		"id":         j.ID,
		"kind":       j.Kind,
		"source":     j.Source,
		"title":      j.Title,
		"state":      j.State,
		"progress":   j.Progress,
		"message":    j.Message,
		"created_at": j.CreatedAt.UTC().Format(time.RFC3339),
	}
}

func jobsJSON(list []store.Job) []map[string]any {
	out := make([]map[string]any, 0, len(list))
	for _, j := range list {
		out = append(out, jobJSON(j))
	}
	return out
}

// handleSubmitJob queues a torrent/download job. Kind is inferred from the
// source when not given (magnet: → torrent, else download). Gated on
// torrent:write.
//
// POST /v1/jobs {source, kind?, title?}
func (s *Server) handleSubmitJob(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	if s.jobs == nil {
		writeErr(w, http.StatusServiceUnavailable, "jobs engine not available")
		return
	}
	var req struct {
		Source string `json:"source"`
		Kind   string `json:"kind"`
		Title  string `json:"title"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Source) == "" {
		writeErr(w, http.StatusBadRequest, "source required")
		return
	}
	kind := req.Kind
	if kind == "" {
		if strings.HasPrefix(req.Source, "magnet:") {
			kind = store.JobKindTorrent
		} else {
			kind = store.JobKindDownload
		}
	}
	if kind != store.JobKindTorrent && kind != store.JobKindDownload {
		writeErr(w, http.StatusBadRequest, "unsupported job kind")
		return
	}
	title := req.Title
	if title == "" {
		title = titleFor(req.Source)
	}
	job, err := s.jobs.Submit(p.UserID, kind, req.Source, title)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, jobJSON(*job))
}

func (s *Server) handleCancelJob(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	if err := s.jobs.Cancel(p.UserID, chi.URLParam(r, "id")); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleRetryJob(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	if err := s.jobs.Retry(p.UserID, chi.URLParam(r, "id")); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleClearFinished(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	if err := s.jobs.ClearFinished(p.UserID); err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleWatchJobs streams the caller's job list as SSE. Each event is the full
// snapshot (reconnect-safe). The stream is capped so a revoked device can't
// listen forever; the client reconnects with a fresh token.
//
// GET /v1/jobs/watch
func (s *Server) handleWatchJobs(w http.ResponseWriter, r *http.Request) {
	p := PrincipalFrom(r.Context())
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	ch, unsubscribe := s.jobs.Watch(p.UserID)
	defer unsubscribe()

	// Cap the stream lifetime to the access-token horizon; client reconnects.
	deadline := time.NewTimer(30 * time.Minute)
	defer deadline.Stop()
	// Heartbeat so proxies/idle timeouts along serve→Caddy never reap it.
	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()

	send := func(snapshot []store.Job) {
		payload, _ := json.Marshal(map[string]any{"jobs": jobsJSON(snapshot)})
		fmt.Fprintf(w, "data: %s\n\n", payload)
		flusher.Flush()
	}

	for {
		select {
		case <-r.Context().Done():
			return
		case <-deadline.C:
			fmt.Fprint(w, "event: reconnect\ndata: {}\n\n")
			flusher.Flush()
			return
		case <-heartbeat.C:
			fmt.Fprint(w, ": keepalive\n\n")
			flusher.Flush()
		case snap, open := <-ch:
			if !open {
				return
			}
			send(snap)
		}
	}
}

// titleFor derives a display title from a magnet dn= or a URL tail.
func titleFor(source string) string {
	if u, err := url.Parse(source); err == nil {
		if dn := u.Query().Get("dn"); dn != "" {
			return dn
		}
		if segs := strings.Split(strings.TrimRight(u.Path, "/"), "/"); len(segs) > 0 {
			if tail := segs[len(segs)-1]; tail != "" {
				return tail
			}
		}
	}
	return source
}
