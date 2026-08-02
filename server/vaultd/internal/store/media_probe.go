package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// MediaProbe returns a cached ffprobe result, or ErrNotFound.
func (r *ReadStore) MediaProbe(ctx context.Context, key string) (string, error) {
	var info string
	err := r.db.QueryRowContext(ctx,
		`SELECT info FROM media_probe WHERE cache_key = ?`, key).Scan(&info)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return info, err
}

// PutMediaProbe caches a probe result. The key embeds size+mtime, so a
// changed file simply lands under a new key rather than needing invalidation.
func (w *WriteStore) PutMediaProbe(ctx context.Context, key, info string) error {
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO media_probe (cache_key, info, probed_at) VALUES (?, ?, ?)
		ON CONFLICT (cache_key) DO UPDATE SET
			info = excluded.info, probed_at = excluded.probed_at`,
		key, info, time.Now().Unix())
	return err
}

// PruneMediaProbes drops entries not read since [before] — stale keys from
// files that were edited or deleted accumulate otherwise.
func (w *WriteStore) PruneMediaProbes(ctx context.Context, before time.Time) (int, error) {
	res, err := w.db.ExecContext(ctx,
		`DELETE FROM media_probe WHERE probed_at < ?`, before.Unix())
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}
