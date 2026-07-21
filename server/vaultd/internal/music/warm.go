package music

import (
	"bytes"
	"context"
	"net/http"
	"os"
	"sync"
	"time"
)

// maxWarmBytesPerTrack caps a single warmed file so a mis-tagged giant can't
// blow up RAM. Music tracks are ~5–12 MB; 32 MB is generous headroom.
const maxWarmBytesPerTrack = 32 << 20

// warmEntry is one catalog track held in RAM, ready to serve with Range.
type warmEntry struct {
	data    []byte
	modTime time.Time
	name    string // basename, for http.ServeContent's content-type sniff
}

// warmCache keeps the household's hottest catalog tracks in memory so the most-
// played songs start instantly and never touch disk. It's a pure read-through
// accelerator over CatalogTrackPath — a miss just falls back to ServeFile, so
// the cache can be empty, stale, or disabled with zero correctness impact.
type warmCache struct {
	mu   sync.RWMutex
	byID map[string]warmEntry
}

// get returns the warmed entry for a catalog track ID, if present.
func (c *warmCache) get(id string) (warmEntry, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	e, ok := c.byID[id]
	return e, ok
}

// replace atomically swaps the whole warmed set (simpler and race-free vs.
// mutating in place; the set is tiny).
func (c *warmCache) replace(m map[string]warmEntry) {
	c.mu.Lock()
	c.byID = m
	c.mu.Unlock()
}

// StartWarmCache warms the top-[count] most-played catalog tracks into RAM and
// keeps them fresh on [interval]. Best-effort: any error is logged and the
// stream path falls back to disk. Returns immediately; the loop runs until
// [ctx] is cancelled. A count <= 0 disables warming.
func (s *Service) StartWarmCache(ctx context.Context, count int, interval time.Duration) {
	if count <= 0 {
		return
	}
	if interval <= 0 {
		interval = 15 * time.Minute
	}
	s.warm = &warmCache{byID: map[string]warmEntry{}}
	go func() {
		s.refreshWarm(ctx, count)
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				s.refreshWarm(ctx, count)
			}
		}
	}()
}

// refreshWarm rebuilds the warmed set from the current top-[count] most-played
// catalog tracks (last 30 days). Files larger than [maxWarmBytesPerTrack] or
// that can't be read are skipped, not fatal.
func (s *Service) refreshWarm(ctx context.Context, count int) {
	if s.warm == nil || s.Store == nil {
		return
	}
	ids, err := s.Store.Read().TopCatalogTrackIDs(ctx, 30, count)
	if err != nil {
		s.Log.Warn("warm cache: top tracks query failed", "err", err)
		return
	}
	next := make(map[string]warmEntry, len(ids))
	var total int64
	for _, id := range ids {
		t, err := s.Store.Read().CatalogTrackByID(ctx, id)
		if err != nil {
			continue
		}
		path := s.CatalogTrackPath(t)
		fi, err := os.Stat(path)
		if err != nil || fi.Size() > maxWarmBytesPerTrack {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		next[id] = warmEntry{
			data:    data,
			modTime: fi.ModTime(),
			name:    fi.Name(),
		}
		total += int64(len(data))
	}
	s.warm.replace(next)
	if s.Log != nil {
		s.Log.Info("warm cache refreshed",
			"tracks", len(next), "bytes", total)
	}
}

// ServeWarm serves a catalog track from RAM if it's warmed, returning true when
// it handled the request. http.ServeContent gives full Range/206/If-Modified
// from the in-memory bytes — the same seek behavior as ServeFile, no disk I/O.
// Returns false on a miss so the caller falls back to ServeFile.
func (s *Service) ServeWarm(w http.ResponseWriter, r *http.Request, id string) bool {
	if s.warm == nil {
		return false
	}
	e, ok := s.warm.get(id)
	if !ok {
		return false
	}
	http.ServeContent(w, r, e.name, e.modTime, bytes.NewReader(e.data))
	return true
}
