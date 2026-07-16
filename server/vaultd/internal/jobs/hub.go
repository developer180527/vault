// Package jobs is the background-work engine: a scheduler that runs torrent
// (qBittorrent) and URL (yt-dlp) work, persists state, and streams live
// snapshots to clients over SSE. See DESIGN.md "Job store + live updates".
package jobs

import (
	"sync"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// subscriber receives per-user job snapshots. Its channel holds only the
// LATEST snapshot (coalescing): a slow client never blocks the publisher, it
// just gets the freshest state when it drains.
type subscriber struct {
	userID string
	ch     chan []store.Job
}

// hub fans out job-list changes to SSE subscribers, filtered per user.
type hub struct {
	mu   sync.Mutex
	subs map[*subscriber]struct{}
}

func newHub() *hub {
	return &hub{subs: map[*subscriber]struct{}{}}
}

func (h *hub) subscribe(userID string) *subscriber {
	s := &subscriber{userID: userID, ch: make(chan []store.Job, 1)}
	h.mu.Lock()
	h.subs[s] = struct{}{}
	h.mu.Unlock()
	return s
}

func (h *hub) unsubscribe(s *subscriber) {
	h.mu.Lock()
	delete(h.subs, s)
	h.mu.Unlock()
	close(s.ch)
}

// publish sends a user's current snapshot to that user's subscribers,
// coalescing: if a subscriber's buffer is full, drop the stale snapshot and
// replace it with this newer one. Never blocks.
func (h *hub) publish(userID string, snapshot []store.Job) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for s := range h.subs {
		if s.userID != userID {
			continue
		}
		select {
		case s.ch <- snapshot:
		default:
			// Buffer full: replace the queued-but-unsent snapshot.
			select {
			case <-s.ch:
			default:
			}
			select {
			case s.ch <- snapshot:
			default:
			}
		}
	}
}
