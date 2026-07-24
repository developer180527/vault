package changes

import "testing"

func TestWatchSeesSnapshotThenBumps(t *testing.T) {
	h := NewHub(nil)
	ch, unsub := h.Watch()
	defer unsub()

	first := <-ch // initial snapshot arrives immediately (reconnect-safe)
	if len(first) != 0 {
		t.Fatalf("fresh hub snapshot should be empty, got %v", first)
	}

	h.Bump("music")
	got := <-ch
	if got["music"] == 0 {
		t.Fatalf("music rev missing after bump: %v", got)
	}

	// A second bump must produce a DIFFERENT rev (that's what clients compare).
	h.Bump("music")
	if next := <-ch; next["music"] == got["music"] {
		t.Fatalf("rev did not advance: %v -> %v", got, next)
	}
}

func TestSlowSubscriberCoalesces(t *testing.T) {
	h := NewHub(nil)
	ch, unsub := h.Watch()
	defer unsub()
	<-ch // drain the snapshot

	// Nobody draining: bumps must never block, and the buffered event must be
	// the freshest one.
	for range 10 {
		h.Bump("music")
	}
	h.Bump("movies")
	got := <-ch
	if got["movies"] == 0 {
		t.Fatalf("coalesced event should be the latest (with movies): %v", got)
	}
}

func TestNilHubIsSafe(t *testing.T) {
	var h *Hub
	h.Bump("music") // must not panic — handlers bump unconditionally
}

func TestBootSeedMakesRevsDiffer(t *testing.T) {
	// Two hubs (≈ server restarts) must not reuse small counters like 1,2,3 —
	// otherwise a client that saw rev 2 before the restart would miss the
	// changes behind a fresh hub's rev 2.
	a, b := NewHub(nil), NewHub(nil)
	a.Bump("music")
	b.Bump("music")
	achan, aun := a.Watch()
	bchan, bun := b.Watch()
	defer aun()
	defer bun()
	if (<-achan)["music"] < 1_000_000 || (<-bchan)["music"] < 1_000_000 {
		t.Fatal("revs should be clock-seeded, not small counters")
	}
}
