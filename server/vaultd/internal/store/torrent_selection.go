package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Per-torrent file selection: the files the user asked to keep.
//
// Absent = keep everything, which is what makes this safe to add late — every
// torrent downloaded before the feature existed behaves exactly as it did.

// SetTorrentSelection records which torrent-relative paths to keep. An empty
// list is stored as-is and means "keep nothing", distinct from no row at all.
func (w *WriteStore) SetTorrentSelection(ctx context.Context, hash string, keep []string) error {
	blob, err := json.Marshal(keep)
	if err != nil {
		return err
	}
	_, err = w.db.ExecContext(ctx, `
		INSERT INTO torrent_file_selection (hash, keep, updated_at)
		VALUES (?, ?, ?)
		ON CONFLICT(hash) DO UPDATE SET keep = excluded.keep,
			updated_at = excluded.updated_at`,
		strings.ToLower(hash), string(blob), time.Now().Unix())
	return err
}

// TorrentSelection returns the kept paths and whether a selection exists at
// all. The bool matters: no row means "everything", which is NOT the same as
// a stored empty list.
func (r *ReadStore) TorrentSelection(ctx context.Context, hash string) ([]string, bool, error) {
	var blob string
	err := r.db.QueryRowContext(ctx,
		`SELECT keep FROM torrent_file_selection WHERE hash = ?`,
		strings.ToLower(hash)).Scan(&blob)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, false, nil
		}
		return nil, false, err
	}
	var keep []string
	if err := json.Unmarshal([]byte(blob), &keep); err != nil {
		return nil, false, err
	}
	return keep, true, nil
}

// ClearTorrentSelection drops the record (torrent removed).
func (w *WriteStore) ClearTorrentSelection(ctx context.Context, hash string) error {
	_, err := w.db.ExecContext(ctx,
		`DELETE FROM torrent_file_selection WHERE hash = ?`, strings.ToLower(hash))
	return err
}
