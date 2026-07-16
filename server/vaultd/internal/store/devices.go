package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
)

// Device is one enrolled client device (a phone, a laptop).
type Device struct {
	ID            string
	UserID        string
	Name          string
	Platform      string
	AccessExpires time.Time
	RotatedAt     time.Time
	LastSeen      time.Time
	CreatedAt     time.Time
}

// CreateDevice inserts a device with its initial (hashed) token pair.
func (w *WriteStore) CreateDevice(ctx context.Context, userID, name, platform, accessHash string, accessExpires time.Time, refreshHash string) (*Device, error) {
	d := &Device{
		ID:            uuid.NewString(),
		UserID:        userID,
		Name:          name,
		Platform:      platform,
		AccessExpires: accessExpires,
		CreatedAt:     time.Now(),
	}
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO devices (id, user_id, name, platform, access_hash,
			access_expires, refresh_hash, created_at, last_seen)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		d.ID, userID, name, platform, accessHash, accessExpires.Unix(),
		refreshHash, d.CreatedAt.Unix(), d.CreatedAt.Unix())
	if err != nil {
		return nil, err
	}
	return d, nil
}

// Principal is the authenticated caller resolved from an access token.
type Principal struct {
	UserID   string
	Username string
	Role     string
	DeviceID string
}

// PrincipalByAccessHash resolves a live access token hash to its principal.
// Enforces token expiry and user status in one query — the authn hot path.
func (r *ReadStore) PrincipalByAccessHash(ctx context.Context, hash string, now time.Time) (*Principal, error) {
	var p Principal
	err := r.db.QueryRowContext(ctx, `
		SELECT u.id, u.username, u.role, d.id
		FROM devices d JOIN users u ON u.id = d.user_id
		WHERE d.access_hash = ? AND d.access_expires > ? AND u.status = 'active'`,
		hash, now.Unix()).Scan(&p.UserID, &p.Username, &p.Role, &p.DeviceID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

// RefreshMatch describes which stored refresh secret a presented token hit.
type RefreshMatch struct {
	DeviceID  string
	UserID    string
	Current   bool // matched refresh_hash (normal path)
	RotatedAt time.Time
}

// MatchRefresh finds the device holding this refresh hash, either as the
// current secret or as the previous one (grace-window replay).
func (r *ReadStore) MatchRefresh(ctx context.Context, hash string) (*RefreshMatch, error) {
	var m RefreshMatch
	var cur int
	var rotated int64
	err := r.db.QueryRowContext(ctx, `
		SELECT d.id, d.user_id, (d.refresh_hash = ?), d.rotated_at
		FROM devices d JOIN users u ON u.id = d.user_id
		WHERE (d.refresh_hash = ? OR d.prev_hash = ?) AND u.status = 'active'`,
		hash, hash, hash).Scan(&m.DeviceID, &m.UserID, &cur, &rotated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	m.Current = cur == 1
	m.RotatedAt = time.Unix(rotated, 0)
	return &m, nil
}

// RotateTokens installs a new token pair. When the presented token was the
// CURRENT refresh secret, it becomes prev (grace); on a grace replay the
// stored prev is kept so the window doesn't extend indefinitely.
func (w *WriteStore) RotateTokens(ctx context.Context, deviceID string, fromCurrent bool, accessHash string, accessExpires time.Time, refreshHash string, now time.Time) error {
	var err error
	if fromCurrent {
		_, err = w.db.ExecContext(ctx, `
			UPDATE devices SET prev_hash = refresh_hash, rotated_at = ?,
				refresh_hash = ?, access_hash = ?, access_expires = ?, last_seen = ?
			WHERE id = ?`,
			now.Unix(), refreshHash, accessHash, accessExpires.Unix(), now.Unix(), deviceID)
	} else {
		_, err = w.db.ExecContext(ctx, `
			UPDATE devices SET refresh_hash = ?, access_hash = ?,
				access_expires = ?, last_seen = ?
			WHERE id = ?`,
			refreshHash, accessHash, accessExpires.Unix(), now.Unix(), deviceID)
	}
	return err
}

// RevokeDevice deletes a device (its tokens die with it).
func (w *WriteStore) RevokeDevice(ctx context.Context, deviceID string) error {
	res, err := w.db.ExecContext(ctx, `DELETE FROM devices WHERE id = ?`, deviceID)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ListDevices returns a user's devices (all users when userID is "").
func (r *ReadStore) ListDevices(ctx context.Context, userID string) ([]Device, error) {
	q := `SELECT id, user_id, name, platform, access_expires, rotated_at,
		last_seen, created_at FROM devices`
	args := []any{}
	if userID != "" {
		q += ` WHERE user_id = ?`
		args = append(args, userID)
	}
	q += ` ORDER BY created_at`
	rows, err := r.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		var d Device
		var exp, rot, seen, created int64
		if err := rows.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform,
			&exp, &rot, &seen, &created); err != nil {
			return nil, err
		}
		d.AccessExpires = time.Unix(exp, 0)
		d.RotatedAt = time.Unix(rot, 0)
		d.LastSeen = time.Unix(seen, 0)
		d.CreatedAt = time.Unix(created, 0)
		out = append(out, d)
	}
	return out, rows.Err()
}
