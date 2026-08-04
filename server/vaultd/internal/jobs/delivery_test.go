package jobs

import (
	"context"
	"errors"
	"testing"

	"github.com/developer180527/vault/vaultd/internal/store"
)

// A job bound for a shared catalog must be filed by that destination's
// handler — never by the default, which would quietly drop a movie into one
// person's private downloads instead of the household library.
func TestDeliverRoutesByDestination(t *testing.T) {
	e := New(nil, nil, t.TempDir(), 1, nil)
	var landed string
	e.SetDelivery(DestMovies, func(_ context.Context, _ store.Job, staged string) error {
		landed = staged
		return nil
	})

	if err := e.deliver(store.Job{Dest: DestMovies}, "/staging/Film.mkv"); err != nil {
		t.Fatalf("deliver: %v", err)
	}
	if landed != "/staging/Film.mkv" {
		t.Fatalf("movies handler got %q, want the staged path", landed)
	}
}

// An unknown destination must FAIL rather than fall back to the personal
// library: silently filing shared content into one user's private zone is
// worse than a visible error.
func TestDeliverRefusesUnknownDestination(t *testing.T) {
	e := New(nil, nil, t.TempDir(), 1, nil)
	err := e.deliver(store.Job{Dest: "nowhere"}, "/staging/x.mkv")
	if err == nil {
		t.Fatal("unknown destination silently accepted")
	}
}

// Nothing to move is not an error — some runners legitimately produce no file.
func TestDeliverIgnoresEmptyPath(t *testing.T) {
	e := New(nil, nil, t.TempDir(), 1, nil)
	if err := e.deliver(store.Job{Dest: DestMusic}, ""); err != nil {
		t.Fatalf("empty staged path = %v, want nil", err)
	}
}

// A handler's failure must surface, not be swallowed — otherwise a job reports
// success while its file sits unfiled in staging.
func TestDeliverPropagatesHandlerError(t *testing.T) {
	e := New(nil, nil, t.TempDir(), 1, nil)
	boom := errors.New("disk full")
	e.SetDelivery(DestMusic, func(context.Context, store.Job, string) error {
		return boom
	})
	if err := e.deliver(store.Job{Dest: DestMusic}, "/staging/a.flac"); !errors.Is(err, boom) {
		t.Fatalf("err = %v, want the handler's error", err)
	}
}
