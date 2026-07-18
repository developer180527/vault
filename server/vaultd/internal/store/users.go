package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
)

// User mirrors the users table.
type User struct {
	ID          string
	OIDCIssuer  string // "" until bound
	OIDCSubject string // "" until bound
	Username    string
	Email       string
	DisplayName string
	Role        string // "admin" | "member"
	Status      string // "active" | "disabled"
	CreatedAt   time.Time
}

// ErrNotFound is returned by lookups that matched nothing.
var ErrNotFound = errors.New("not found")

const userCols = `id, COALESCE(oidc_issuer,''), COALESCE(oidc_subject,''),
	username, COALESCE(email,''), display_name, role, status, created_at`

func scanUser(row interface{ Scan(...any) error }) (*User, error) {
	var u User
	var created int64
	err := row.Scan(&u.ID, &u.OIDCIssuer, &u.OIDCSubject, &u.Username,
		&u.Email, &u.DisplayName, &u.Role, &u.Status, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	u.CreatedAt = time.Unix(created, 0)
	return &u, nil
}

// CountUsers reports how many users exist (0 → bootstrap mode).
func (r *ReadStore) CountUsers(ctx context.Context) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM users`).Scan(&n)
	return n, err
}

// UserByOIDC finds the user bound to (issuer, subject).
func (r *ReadStore) UserByOIDC(ctx context.Context, issuer, subject string) (*User, error) {
	return scanUser(r.db.QueryRowContext(ctx,
		`SELECT `+userCols+` FROM users WHERE oidc_issuer=? AND oidc_subject=?`,
		issuer, subject))
}

// PendingUserByEmail finds an invited user (no OIDC identity yet) by email.
func (r *ReadStore) PendingUserByEmail(ctx context.Context, email string) (*User, error) {
	return scanUser(r.db.QueryRowContext(ctx,
		`SELECT `+userCols+` FROM users WHERE email=? AND oidc_subject IS NULL`,
		email))
}

// UserByID fetches one user.
func (r *ReadStore) UserByID(ctx context.Context, id string) (*User, error) {
	return scanUser(r.db.QueryRowContext(ctx,
		`SELECT `+userCols+` FROM users WHERE id=?`, id))
}

// UserByUsername fetches one user by username (CLI convenience).
func (r *ReadStore) UserByUsername(ctx context.Context, username string) (*User, error) {
	return scanUser(r.db.QueryRowContext(ctx,
		`SELECT `+userCols+` FROM users WHERE username=?`, username))
}

// ListUsers returns everyone, oldest first.
func (r *ReadStore) ListUsers(ctx context.Context) ([]User, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT `+userCols+` FROM users ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []User
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *u)
	}
	return out, rows.Err()
}

// CreateUser inserts an invited (or bootstrap-bound) user and returns it.
// issuer/subject may be empty for invites; email is the binding key then.
func (w *WriteStore) CreateUser(ctx context.Context, username, email, displayName, role string, issuer, subject string) (*User, error) {
	u := &User{
		ID:          uuid.NewString(),
		OIDCIssuer:  issuer,
		OIDCSubject: subject,
		Username:    username,
		Email:       email,
		DisplayName: displayName,
		Role:        role,
		Status:      "active",
		CreatedAt:   time.Now(),
	}
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO users (id, oidc_issuer, oidc_subject, username, email,
			display_name, role, status, created_at)
		VALUES (?, NULLIF(?,''), NULLIF(?,''), ?, NULLIF(?,''), ?, ?, 'active', ?)`,
		u.ID, issuer, subject, username, email, displayName, role,
		u.CreatedAt.Unix())
	if err != nil {
		return nil, err
	}
	return u, nil
}

// BindOIDC attaches an OIDC identity to an invited user on first login.
func (w *WriteStore) BindOIDC(ctx context.Context, userID, issuer, subject string) error {
	res, err := w.db.ExecContext(ctx,
		`UPDATE users SET oidc_issuer=?, oidc_subject=? WHERE id=? AND oidc_subject IS NULL`,
		issuer, subject, userID)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetUserStatus enables/disables a user.
func (w *WriteStore) SetUserStatus(ctx context.Context, userID, status string) error {
	_, err := w.db.ExecContext(ctx,
		`UPDATE users SET status=? WHERE id=?`, status, userID)
	return err
}

// SetUserRole promotes/demotes a user ('admin' | 'member'). Blast-radius
// guards (not-self, last-admin) live at the caller — this is mechanism only.
func (w *WriteStore) SetUserRole(ctx context.Context, userID, role string) error {
	_, err := w.db.ExecContext(ctx,
		`UPDATE users SET role=? WHERE id=?`, role, userID)
	return err
}

// CountActiveAdmins backs the last-admin lockout guard (ADMIN.md §5).
func (r *ReadStore) CountActiveAdmins(ctx context.Context) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM users WHERE role='admin' AND status='active'`,
	).Scan(&n)
	return n, err
}
