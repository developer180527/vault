package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
)

// Job states + kinds mirror the client's JobState / JobKind enums exactly.
const (
	JobQueued    = "queued"
	JobRunning   = "running"
	JobCompleted = "completed"
	JobFailed    = "failed"
	JobCanceled  = "canceled"

	JobKindTorrent  = "torrent"
	JobKindDownload = "download"
	JobKindUpload   = "upload"
)

// JobFinished reports whether a state is terminal.
func JobFinished(state string) bool {
	return state == JobCompleted || state == JobFailed || state == JobCanceled
}

// Job is one unit of background work.
type Job struct {
	ID        string
	UserID    string
	Kind      string // torrent | download | upload
	Source    string
	Title     string
	State     string
	Progress  float64 // 0..1
	Message   string
	CreatedAt time.Time
	UpdatedAt time.Time
}

// CreateJob inserts a queued job and returns it.
func (w *WriteStore) CreateJob(ctx context.Context, userID, kind, source, title string) (*Job, error) {
	now := time.Now()
	j := &Job{
		ID:        uuid.NewString(),
		UserID:    userID,
		Kind:      kind,
		Source:    source,
		Title:     title,
		State:     JobQueued,
		CreatedAt: now,
		UpdatedAt: now,
	}
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO jobs (id, user_id, kind, source, title, state, progress,
			message, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 'queued', 0, '', ?, ?)`,
		j.ID, userID, kind, source, title, now.Unix(), now.Unix())
	if err != nil {
		return nil, err
	}
	return j, nil
}

// UpdateJob writes state/progress/message for a job. Used by the workers.
func (w *WriteStore) UpdateJob(ctx context.Context, id, state string, progress float64, message string) error {
	_, err := w.db.ExecContext(ctx, `
		UPDATE jobs SET state=?, progress=?, message=?, updated_at=?
		WHERE id=?`, state, progress, message, time.Now().Unix(), id)
	return err
}

// SetJobState transitions state only (keeps progress/message), guarded by the
// current state so a cancel can't resurrect a finished job.
func (w *WriteStore) SetJobState(ctx context.Context, id, from, to string) (bool, error) {
	res, err := w.db.ExecContext(ctx, `
		UPDATE jobs SET state=?, updated_at=? WHERE id=? AND state=?`,
		to, time.Now().Unix(), id, from)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// JobByID fetches one job.
func (r *ReadStore) JobByID(ctx context.Context, id string) (*Job, error) {
	return scanJob(r.db.QueryRowContext(ctx, jobSelect+` WHERE id=?`, id))
}

// JobsForUser lists a user's jobs, newest first.
func (r *ReadStore) JobsForUser(ctx context.Context, userID string) ([]Job, error) {
	return queryJobs(ctx, r.db, jobSelect+` WHERE user_id=? ORDER BY created_at DESC`, userID)
}

// JobsInState lists all jobs in a state (workers/reconciliation), oldest first
// so FIFO fairness has a stable order.
func (r *ReadStore) JobsInState(ctx context.Context, state string) ([]Job, error) {
	return queryJobs(ctx, r.db, jobSelect+` WHERE state=? ORDER BY created_at ASC`, state)
}

// ClearFinished deletes a user's terminal jobs.
func (w *WriteStore) ClearFinished(ctx context.Context, userID string) error {
	_, err := w.db.ExecContext(ctx, `
		DELETE FROM jobs WHERE user_id=? AND state IN ('completed','failed','canceled')`,
		userID)
	return err
}

// ReconcileRunning fails any job still marked running at startup — a crash
// left them orphaned; the queue must never freeze on them (DESIGN.md).
func (w *WriteStore) ReconcileRunning(ctx context.Context) (int, error) {
	res, err := w.db.ExecContext(ctx, `
		UPDATE jobs SET state='failed', message='interrupted by server restart',
			updated_at=? WHERE state='running'`, time.Now().Unix())
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

const jobSelect = `SELECT id, user_id, kind, source, title, state, progress,
	message, created_at, updated_at FROM jobs`

func scanJob(row interface{ Scan(...any) error }) (*Job, error) {
	var j Job
	var created, updated int64
	err := row.Scan(&j.ID, &j.UserID, &j.Kind, &j.Source, &j.Title, &j.State,
		&j.Progress, &j.Message, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	j.CreatedAt = time.Unix(created, 0)
	j.UpdatedAt = time.Unix(updated, 0)
	return &j, nil
}

func queryJobs(ctx context.Context, db *sql.DB, q string, args ...any) ([]Job, error) {
	rows, err := db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}
