package store

import (
	"context"
	"time"
)

// AuditEntry is one append-only admin-action record (ADMIN.md §4).
type AuditEntry struct {
	ID         int64
	ActorUser  string
	Action     string
	TargetKind string
	TargetID   string
	Summary    string
	RequestID  string
	RemoteAddr string
	CreatedAt  time.Time
}

// InsertAudit appends one audit row. Failures are the CALLER's problem to log
// (never to abort the action — the mutation already happened).
func (w *WriteStore) InsertAudit(ctx context.Context, e AuditEntry) error {
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO admin_audit (actor_user, action, target_kind, target_id,
			summary, request_id, remote_addr, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		e.ActorUser, e.Action, e.TargetKind, e.TargetID,
		e.Summary, e.RequestID, e.RemoteAddr, time.Now().Unix())
	return err
}

// ListAudit returns the newest [limit] entries.
func (r *ReadStore) ListAudit(ctx context.Context, limit int) ([]AuditEntry, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, actor_user, action, target_kind, target_id, summary,
			request_id, remote_addr, created_at
		FROM admin_audit ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AuditEntry
	for rows.Next() {
		var e AuditEntry
		var created int64
		if err := rows.Scan(&e.ID, &e.ActorUser, &e.Action, &e.TargetKind,
			&e.TargetID, &e.Summary, &e.RequestID, &e.RemoteAddr, &created); err != nil {
			return nil, err
		}
		e.CreatedAt = time.Unix(created, 0)
		out = append(out, e)
	}
	return out, rows.Err()
}

// CountListens backs the System page's library-activity card.
func (r *ReadStore) CountListens(ctx context.Context) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM listens`).Scan(&n)
	return n, err
}

// SetCatalogHasArt flips the has_art flag (e.g. after an admin uploads a
// cover for a track whose file has no embedded art).
func (w *WriteStore) SetCatalogHasArt(ctx context.Context, id string, has bool) error {
	v := 0
	if has {
		v = 1
	}
	_, err := w.db.ExecContext(ctx,
		`UPDATE catalog_tracks SET has_art=? WHERE id=?`, v, id)
	return err
}
