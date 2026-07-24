package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// handleWatchChanges streams the change hub's revision map as SSE. Any
// authenticated device may watch: events carry only {topic: rev} — no data —
// so there's nothing to gate per-grant; actually fetching the changed listing
// still goes through the granted endpoints. Mirrors the jobs stream: full
// snapshot per event (reconnect-safe), lifetime capped so a revoked device
// can't listen forever, heartbeats so idle proxies never reap it.
//
// GET /v1/changes/watch
func (s *Server) handleWatchChanges(w http.ResponseWriter, r *http.Request) {
	if s.changes == nil {
		writeErr(w, http.StatusNotFound, "changes unavailable")
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	ch, unsubscribe := s.changes.Watch()
	defer unsubscribe()

	deadline := time.NewTimer(30 * time.Minute)
	defer deadline.Stop()
	heartbeat := time.NewTicker(25 * time.Second)
	defer heartbeat.Stop()

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
		case revs, open := <-ch:
			if !open {
				return
			}
			payload, _ := json.Marshal(revs)
			fmt.Fprintf(w, "data: %s\n\n", payload)
			flusher.Flush()
		}
	}
}
