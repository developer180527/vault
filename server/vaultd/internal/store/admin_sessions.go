package store

import (
	"context"
	"time"

	"github.com/google/uuid"
)

// Admin-panel browser sessions (docs/backend/ADMIN.md). The cookie carries an
// opaque random token; only its sha256 is stored — a DB leak reveals nothing
// replayable, same as device tokens.

// CreateAdminSession records a new session for [userID].
func (w *WriteStore) CreateAdminSession(ctx context.Context, userID, tokenHash string, expires time.Time) error {
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO admin_sessions (id, user_id, token_hash, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?)`,
		uuid.NewString(), userID, tokenHash, time.Now().Unix(), expires.Unix())
	return err
}

// AdminSessionUser resolves a live session token hash to its user row.
// Expiry uses strict >: a token is dead AT its expiry instant. Role/status
// enforcement is the caller's (middleware re-checks on every request, so a
// demoted or disabled admin is out on their next click, not at next login).
func (r *ReadStore) AdminSessionUser(ctx context.Context, tokenHash string, now time.Time) (*User, error) {
	// userCols is unqualified (ambiguous under the join) — qualify inline.
	row := r.db.QueryRowContext(ctx, `
		SELECT u.id, COALESCE(u.oidc_issuer,''), COALESCE(u.oidc_subject,''),
			u.username, COALESCE(u.email,''), u.display_name, u.role,
			u.status, u.created_at
		FROM users u
		JOIN admin_sessions s ON s.user_id = u.id
		WHERE s.token_hash = ? AND s.expires_at > ?`,
		tokenHash, now.Unix())
	return scanUser(row)
}

// DeleteAdminSession revokes one session (logout). Unknown hashes are a
// no-op — logout must be idempotent.
func (w *WriteStore) DeleteAdminSession(ctx context.Context, tokenHash string) error {
	_, err := w.db.ExecContext(ctx,
		`DELETE FROM admin_sessions WHERE token_hash = ?`, tokenHash)
	return err
}

// PruneAdminSessions drops expired rows (called opportunistically at login —
// no daemon needed at this scale).
func (w *WriteStore) PruneAdminSessions(ctx context.Context, now time.Time) error {
	_, err := w.db.ExecContext(ctx,
		`DELETE FROM admin_sessions WHERE expires_at <= ?`, now.Unix())
	return err
}
