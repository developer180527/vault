package jobs

import (
	"context"
	"log/slog"
	"sort"
	"sync"

	"github.com/developer180527/vault/vaultd/internal/library"
	"github.com/developer180527/vault/vaultd/internal/store"
)

// Runner executes one job to completion. It MUST honor ctx cancellation
// (return promptly when canceled) and report progress via report. On success
// it returns the absolute path of what it produced in staging, which the
// engine then atomically moves into the owner's downloads/.
type Runner interface {
	Run(ctx context.Context, job store.Job, report func(progress float64, message string)) (stagedPath string, err error)
}

// Engine schedules and runs jobs: one shared queue with a concurrency cap and
// per-user fairness, so one member queueing fifty downloads can't starve the
// others (DESIGN.md). Torrent and download work are just different Runners.
type Engine struct {
	log      *slog.Logger
	store    *store.Store
	hub      *hub
	dataRoot string
	runners  map[string]Runner // kind → runner
	maxConc  int

	ctx    context.Context
	cancel context.CancelFunc

	// wg tracks WORKER goroutines only (the ones that touch the filesystem);
	// Stop waits on it so shutdown is synchronous — no runner keeps writing
	// into staging after Stop returns (this raced TempDir cleanup in tests).
	wg sync.WaitGroup

	mu      sync.Mutex
	running map[string]context.CancelFunc // jobID → cancel
}

// New builds an engine. Runners are keyed by job kind ("torrent","download").
func New(log *slog.Logger, st *store.Store, dataRoot string, maxConcurrent int, runners map[string]Runner) *Engine {
	ctx, cancel := context.WithCancel(context.Background())
	return &Engine{
		log:      log,
		store:    st,
		hub:      newHub(),
		dataRoot: dataRoot,
		runners:  runners,
		maxConc:  maxConcurrent,
		ctx:      ctx,
		cancel:   cancel,
		running:  map[string]context.CancelFunc{},
	}
}

// Start reconciles crashed jobs then kicks the scheduler.
func (e *Engine) Start() {
	n, err := e.store.Write().ReconcileRunning(e.ctx)
	if err != nil {
		e.log.Error("job reconcile failed", "err", err)
	} else if n > 0 {
		e.log.Warn("failed orphaned running jobs from previous run", "count", n)
	}
	e.schedule()
}

// Stop cancels all running jobs and WAITS for their worker goroutines to
// finish. The mu barrier after cancel orders things safely: any schedule()
// already holding the lock completes its wg.Add first; any later schedule()
// sees the canceled context and starts nothing.
func (e *Engine) Stop() {
	e.cancel()
	e.mu.Lock() // barrier: flush any schedule() that raced the cancel
	e.mu.Unlock()
	e.wg.Wait()
}

// Submit creates a queued job and triggers scheduling.
func (e *Engine) Submit(userID, kind, source, title string) (*store.Job, error) {
	j, err := e.store.Write().CreateJob(e.ctx, userID, kind, source, title)
	if err != nil {
		return nil, err
	}
	e.log.Info("job submitted", "id", j.ID, "kind", kind, "user", userID)
	e.publish(userID)
	e.schedule()
	return j, nil
}

// Cancel stops a queued or running job.
func (e *Engine) Cancel(userID, jobID string) error {
	j, err := e.store.Read().JobByID(e.ctx, jobID)
	if err != nil {
		return err
	}
	if j.UserID != userID || store.JobFinished(j.State) {
		return nil
	}
	e.mu.Lock()
	cancel, isRunning := e.running[jobID]
	e.mu.Unlock()
	if isRunning {
		cancel() // the runner returns; completion marks it canceled
	} else {
		_, _ = e.store.Write().SetJobState(e.ctx, jobID, store.JobQueued, store.JobCanceled)
	}
	e.publish(userID)
	e.schedule()
	return nil
}

// Retry re-queues a failed/canceled job.
func (e *Engine) Retry(userID, jobID string) error {
	j, err := e.store.Read().JobByID(e.ctx, jobID)
	if err != nil {
		return err
	}
	if j.UserID != userID || (j.State != store.JobFailed && j.State != store.JobCanceled) {
		return nil
	}
	if err := e.store.Write().UpdateJob(e.ctx, jobID, store.JobQueued, 0, ""); err != nil {
		return err
	}
	e.publish(userID)
	e.schedule()
	return nil
}

// ClearFinished drops a user's terminal jobs.
func (e *Engine) ClearFinished(userID string) error {
	if err := e.store.Write().ClearFinished(e.ctx, userID); err != nil {
		return err
	}
	e.publish(userID)
	return nil
}

// Watch returns a subscriber channel seeded with the current snapshot and an
// unsubscribe func. The SSE handler streams from the channel.
func (e *Engine) Watch(userID string) (<-chan []store.Job, func()) {
	sub := e.hub.subscribe(userID)
	// Seed immediately so a fresh listener gets state without waiting for a
	// change (reconnect safety — every connection starts with a full snapshot).
	go e.publish(userID)
	return sub.ch, func() { e.hub.unsubscribe(sub) }
}

// Snapshot returns a user's current jobs (for the initial SSE payload / tests).
func (e *Engine) Snapshot(userID string) ([]store.Job, error) {
	return e.store.Read().JobsForUser(e.ctx, userID)
}

// --- scheduling ---

func (e *Engine) schedule() {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.ctx.Err() != nil {
		return // shutting down — never start work after Stop begins
	}
	for len(e.running) < e.maxConc {
		job := e.pickFair()
		if job == nil {
			return
		}
		e.startLocked(*job)
	}
}

// pickFair chooses the next queued job: the user with the fewest running jobs
// first, oldest job breaking ties. Round-robin fairness across users.
func (e *Engine) pickFair() *store.Job {
	queued, err := e.store.Read().JobsInState(e.ctx, store.JobQueued)
	if err != nil || len(queued) == 0 {
		return nil
	}
	runningByUser := map[string]int{}
	for id := range e.running {
		if j, err := e.store.Read().JobByID(e.ctx, id); err == nil {
			runningByUser[j.UserID]++
		}
	}
	sort.SliceStable(queued, func(i, j int) bool {
		ri, rj := runningByUser[queued[i].UserID], runningByUser[queued[j].UserID]
		if ri != rj {
			return ri < rj
		}
		return queued[i].CreatedAt.Before(queued[j].CreatedAt)
	})
	// Skip kinds with no runner (misconfig) rather than spinning on them.
	for i := range queued {
		if _, ok := e.runners[queued[i].Kind]; ok {
			return &queued[i]
		}
	}
	return nil
}

// startLocked launches a job. Caller holds e.mu.
func (e *Engine) startLocked(job store.Job) {
	runner := e.runners[job.Kind]
	jobCtx, cancel := context.WithCancel(e.ctx)
	e.running[job.ID] = cancel
	_ = e.store.Write().UpdateJob(e.ctx, job.ID, store.JobRunning, 0, "")
	go e.publish(job.UserID)

	e.wg.Add(1) // under e.mu with ctx checked — ordered before any Stop.Wait
	go func() {
		defer e.wg.Done()
		report := func(progress float64, message string) {
			_ = e.store.Write().UpdateJob(e.ctx, job.ID, store.JobRunning, progress, message)
			e.publish(job.UserID)
		}
		staged, err := runner.Run(jobCtx, job, report)
		e.finish(job, jobCtx, staged, err)
		cancel()
	}()
}

// finish records terminal state and, on success, moves the artifact into the
// owner's library. Distinguishes cancellation from failure.
func (e *Engine) finish(job store.Job, jobCtx context.Context, staged string, runErr error) {
	e.mu.Lock()
	delete(e.running, job.ID)
	e.mu.Unlock()

	switch {
	case jobCtx.Err() == context.Canceled:
		_, _ = e.store.Write().SetJobState(e.ctx, job.ID, store.JobRunning, store.JobCanceled)
	case runErr != nil:
		e.log.Warn("job failed", "id", job.ID, "err", runErr)
		_ = e.store.Write().UpdateJob(e.ctx, job.ID, store.JobFailed, 0, runErr.Error())
	default:
		if err := e.deliver(job, staged); err != nil {
			e.log.Error("job delivery failed", "id", job.ID, "err", err)
			_ = e.store.Write().UpdateJob(e.ctx, job.ID, store.JobFailed, 1, "delivery: "+err.Error())
		} else {
			_ = e.store.Write().UpdateJob(e.ctx, job.ID, store.JobCompleted, 1, "")
			e.log.Info("job completed", "id", job.ID, "kind", job.Kind)
		}
	}
	e.publish(job.UserID)
	e.schedule()
}

// deliver moves the staged artifact into the user's downloads/ (atomic
// ingest + EXDEV fallback). Empty staged path = nothing to move (rare).
func (e *Engine) deliver(job store.Job, staged string) error {
	if staged == "" {
		return nil
	}
	user, err := e.store.Read().UserByID(e.ctx, job.UserID)
	if err != nil {
		return err
	}
	_, err = library.MoveInto(e.dataRoot, user.Username, "downloads", staged)
	return err
}

func (e *Engine) publish(userID string) {
	snap, err := e.store.Read().JobsForUser(e.ctx, userID)
	if err != nil {
		e.log.Error("snapshot failed", "user", userID, "err", err)
		return
	}
	e.hub.publish(userID, snap)
}
