package jobs

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/developer180527/vault/vaultd/internal/library"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// fakeRunner blocks until released, so tests control lifecycle precisely. It
// stages a real file so delivery (MoveInto) is exercised end to end.
type fakeRunner struct {
	staging  string
	mu       sync.Mutex
	release  map[string]chan error // jobID → completion signal
	started  int32
	maxSeen  int32
	current  int32
	failWord string
}

func newFakeRunner(staging string) *fakeRunner {
	return &fakeRunner{staging: staging, release: map[string]chan error{}, failWord: "boom"}
}

func (f *fakeRunner) gate(jobID string) chan error {
	f.mu.Lock()
	defer f.mu.Unlock()
	ch, ok := f.release[jobID]
	if !ok {
		ch = make(chan error, 1)
		f.release[jobID] = ch
	}
	return ch
}

func (f *fakeRunner) Run(ctx context.Context, job store.Job, report func(float64, string)) (string, error) {
	atomic.AddInt32(&f.started, 1)
	c := atomic.AddInt32(&f.current, 1)
	for {
		old := atomic.LoadInt32(&f.maxSeen)
		if c <= old || atomic.CompareAndSwapInt32(&f.maxSeen, old, c) {
			break
		}
	}
	defer atomic.AddInt32(&f.current, -1)
	report(0.5, "working")

	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case err := <-f.gate(job.ID):
		if err != nil {
			return "", err
		}
		// Stage a real artifact for delivery.
		p := filepath.Join(f.staging, "out-"+job.ID+".bin")
		if e := os.WriteFile(p, []byte("data"), 0o600); e != nil {
			return "", e
		}
		return p, nil
	}
}

func setup(t *testing.T, maxConc int) (*Engine, *fakeRunner, *store.Store, string) {
	t.Helper()
	dataRoot := t.TempDir()
	staging := filepath.Join(dataRoot, "staging")
	if err := os.MkdirAll(staging, 0o770); err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "v.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	fr := newFakeRunner(staging)
	eng := New(slog.New(slog.DiscardHandler), st, dataRoot, maxConc,
		map[string]Runner{"download": fr})
	eng.Start()
	t.Cleanup(eng.Stop)
	return eng, fr, st, dataRoot
}

// mkUser creates a user + library so delivery has a home.
func mkUser(t *testing.T, st *store.Store, dataRoot, name string) string {
	t.Helper()
	u, err := st.Write().CreateUser(context.Background(), name, name+"@x.test", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := library.Ensure(dataRoot, name); err != nil {
		t.Fatal(err)
	}
	return u.ID
}

func waitState(t *testing.T, st *store.Store, jobID, want string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		j, err := st.Read().JobByID(context.Background(), jobID)
		if err == nil && j.State == want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	j, _ := st.Read().JobByID(context.Background(), jobID)
	t.Fatalf("job %s state = %q, want %q", jobID, j.State, want)
}

func TestSubmitRunsAndDelivers(t *testing.T) {
	eng, fr, st, dataRoot := setup(t, 2)
	uid := mkUser(t, st, dataRoot, "venu")

	j, err := eng.Submit(uid, "download", "https://x.test/a", "a")
	if err != nil {
		t.Fatal(err)
	}
	waitState(t, st, j.ID, store.JobRunning)
	fr.gate(j.ID) <- nil // let it finish
	waitState(t, st, j.ID, store.JobCompleted)

	// Delivered into the user's downloads/.
	entries, _ := os.ReadDir(filepath.Join(dataRoot, "users", "venu", "downloads"))
	if len(entries) != 1 {
		t.Fatalf("expected 1 delivered file, got %d", len(entries))
	}
}

func TestConcurrencyCapAndFairness(t *testing.T) {
	eng, fr, st, dataRoot := setup(t, 2)
	venu := mkUser(t, st, dataRoot, "venu")
	maya := mkUser(t, st, dataRoot, "maya")

	// venu floods 3 jobs first (v0,v1 fill both slots; v2 queues), THEN maya
	// submits — so maya's job is younger than venu's queued v2.
	var venuJobs []string
	for i := 0; i < 3; i++ {
		j, _ := eng.Submit(venu, "download", fmt.Sprintf("v%d", i), "v")
		venuJobs = append(venuJobs, j.ID)
	}
	mj, _ := eng.Submit(maya, "download", "m0", "m")

	// Cap holds at 2 concurrent.
	time.Sleep(100 * time.Millisecond)
	if int(atomic.LoadInt32(&fr.maxSeen)) > 2 {
		t.Fatalf("max concurrent = %d, want <= 2", fr.maxSeen)
	}
	waitState(t, st, venuJobs[0], store.JobRunning)
	waitState(t, st, venuJobs[1], store.JobRunning)

	// Free ONE slot: fairness must hand it to maya (0 running) over venu's
	// OLDER queued v2 (venu still has 1 running) — that's the anti-starvation
	// guarantee, and it beats FIFO age.
	fr.gate(venuJobs[0]) <- nil
	waitState(t, st, venuJobs[0], store.JobCompleted)
	waitState(t, st, mj.ID, store.JobRunning)
	if j, _ := st.Read().JobByID(context.Background(), venuJobs[2]); j.State != store.JobQueued {
		t.Fatalf("venu v2 should still be queued (maya jumped ahead), got %q", j.State)
	}

	// Drain everything.
	for _, id := range append(venuJobs[1:], mj.ID) {
		fr.gate(id) <- nil
	}
	for _, id := range append(venuJobs, mj.ID) {
		waitState(t, st, id, store.JobCompleted)
	}
}

func TestCancelRunningAndRetry(t *testing.T) {
	eng, fr, st, dataRoot := setup(t, 1)
	uid := mkUser(t, st, dataRoot, "venu")

	j, _ := eng.Submit(uid, "download", "https://x.test/a", "a")
	waitState(t, st, j.ID, store.JobRunning)

	if err := eng.Cancel(uid, j.ID); err != nil {
		t.Fatal(err)
	}
	waitState(t, st, j.ID, store.JobCanceled)

	// Retry re-queues and runs again.
	if err := eng.Retry(uid, j.ID); err != nil {
		t.Fatal(err)
	}
	waitState(t, st, j.ID, store.JobRunning)
	// The retried run reuses the same jobID gate; release it to finish.
	fr.gate(j.ID) <- nil
	waitState(t, st, j.ID, store.JobCompleted)
}

func TestFailureAndClearFinished(t *testing.T) {
	eng, fr, st, dataRoot := setup(t, 1)
	uid := mkUser(t, st, dataRoot, "venu")

	j, _ := eng.Submit(uid, "download", "https://x.test/fail", "f")
	waitState(t, st, j.ID, store.JobRunning)
	fr.gate(j.ID) <- fmt.Errorf("boom")
	waitState(t, st, j.ID, store.JobFailed)

	if err := eng.ClearFinished(uid); err != nil {
		t.Fatal(err)
	}
	jobs, _ := eng.Snapshot(uid)
	if len(jobs) != 0 {
		t.Fatalf("clearFinished left %d jobs", len(jobs))
	}
}

func TestWatchSeedsAndUpdates(t *testing.T) {
	eng, fr, st, dataRoot := setup(t, 1)
	uid := mkUser(t, st, dataRoot, "venu")

	ch, cancel := eng.Watch(uid)
	defer cancel()

	// Seed snapshot (empty).
	select {
	case snap := <-ch:
		if len(snap) != 0 {
			t.Fatalf("seed snapshot not empty: %d", len(snap))
		}
	case <-time.After(time.Second):
		t.Fatal("no seed snapshot")
	}

	j, _ := eng.Submit(uid, "download", "https://x.test/a", "a")
	// A snapshot containing the job arrives.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case snap := <-ch:
			if len(snap) == 1 && snap[0].ID == j.ID {
				fr.gate(j.ID) <- nil
				return
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	t.Fatal("job never appeared on watch stream")
}
