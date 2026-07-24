// Package changes is the server→client "something changed" signal: a tiny
// in-process hub of per-topic revision counters, fanned out to clients over
// SSE (GET /v1/changes/watch). It deliberately carries NO payload — just
// {topic: rev} — so it can never leak data across grant boundaries; a client
// that sees a topic tick re-fetches through the normal (authorized) listing
// endpoints. This is what lets an admin-panel artwork upload appear in the
// app without a restart: bump("music") → clients invalidate → re-list →
// fresh art_version → new `?v=` art URL busts every image cache.
package changes

import (
	"sync"
	"time"
)

// Hub holds the revision counters and the SSE subscribers. Revisions are
// per-boot but SEEDED from the boot clock, so after a server restart every
// topic's rev differs from what clients last saw — they refresh once and
// resync, instead of missing changes made while they were disconnected.
type Hub struct {
	mu   sync.Mutex
	revs map[string]int64
	subs map[chan map[string]int64]struct{}
	seed int64
}

func NewHub() *Hub {
	return &Hub{
		revs: map[string]int64{},
		subs: map[chan map[string]int64]struct{}{},
		seed: time.Now().UnixMilli(),
	}
}

// Bump increments a topic's revision and fans the full rev map out to every
// subscriber. Nil-safe so handlers can bump unconditionally (tests build
// servers without a hub). Never blocks: each subscriber channel holds only
// the LATEST map — a slow client just gets the freshest state when it drains.
func (h *Hub) Bump(topic string) {
	if h == nil {
		return
	}
	h.mu.Lock()
	if h.revs[topic] == 0 {
		h.revs[topic] = h.seed
	}
	h.revs[topic]++
	snap := h.snapshotLocked()
	for ch := range h.subs {
		select {
		case ch <- snap:
		default: // full: replace the queued-but-unsent map with this newer one
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- snap:
			default:
			}
		}
	}
	h.mu.Unlock()
}

// Watch subscribes: the returned channel first receives the current snapshot
// (reconnect-safe — a client compares against what it last saw), then every
// future bump. Call unsubscribe exactly once; the channel closes.
func (h *Hub) Watch() (<-chan map[string]int64, func()) {
	ch := make(chan map[string]int64, 1)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	ch <- h.snapshotLocked()
	h.mu.Unlock()
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			h.mu.Lock()
			delete(h.subs, ch)
			h.mu.Unlock()
			close(ch)
		})
	}
}

func (h *Hub) snapshotLocked() map[string]int64 {
	m := make(map[string]int64, len(h.revs))
	for k, v := range h.revs {
		m[k] = v
	}
	return m
}
