package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
)

// SyncedFolder is a folder a device pushed into the vault, with the provenance
// the app shows in its info panel.
type SyncedFolder struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	RelPath        string `json:"rel_path"`
	OriginDevice   string `json:"origin_device"`
	OriginPlatform string `json:"origin_platform"`
	CreatedAt      int64  `json:"created_at"`
	LastSyncAt     int64  `json:"last_sync_at"`
	FileCount      int    `json:"file_count"`
	TotalBytes     int64  `json:"total_bytes"`
}

// CreateSyncedFolder records a new synced folder (the caller has already
// created the directory in the Files zone).
func (w *WriteStore) CreateSyncedFolder(ctx context.Context, userID string, f SyncedFolder) (*SyncedFolder, error) {
	f.ID = uuid.NewString()
	f.CreatedAt = time.Now().Unix()
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO synced_folders (id, owner_id, name, rel_path, origin_device,
			origin_platform, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		f.ID, userID, f.Name, f.RelPath, f.OriginDevice, f.OriginPlatform, f.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &f, nil
}

// SyncedFoldersForUser lists a user's synced folders, newest first.
func (r *ReadStore) SyncedFoldersForUser(ctx context.Context, userID string) ([]SyncedFolder, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, name, rel_path, origin_device, origin_platform, created_at,
			last_sync_at, file_count, total_bytes
		FROM synced_folders WHERE owner_id = ? ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SyncedFolder
	for rows.Next() {
		var f SyncedFolder
		if err := rows.Scan(&f.ID, &f.Name, &f.RelPath, &f.OriginDevice,
			&f.OriginPlatform, &f.CreatedAt, &f.LastSyncAt, &f.FileCount,
			&f.TotalBytes); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// SyncedFolderByID fetches one synced folder, owner-scoped.
func (r *ReadStore) SyncedFolderByID(ctx context.Context, userID, id string) (*SyncedFolder, error) {
	row := r.db.QueryRowContext(ctx, `
		SELECT id, name, rel_path, origin_device, origin_platform, created_at,
			last_sync_at, file_count, total_bytes
		FROM synced_folders WHERE id = ? AND owner_id = ?`, id, userID)
	var f SyncedFolder
	err := row.Scan(&f.ID, &f.Name, &f.RelPath, &f.OriginDevice,
		&f.OriginPlatform, &f.CreatedAt, &f.LastSyncAt, &f.FileCount, &f.TotalBytes)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &f, nil
}

// TouchSyncedFolder records the tally after a device finishes a sync push.
func (w *WriteStore) TouchSyncedFolder(ctx context.Context, userID, id string, fileCount int, totalBytes int64) error {
	res, err := w.db.ExecContext(ctx, `
		UPDATE synced_folders SET last_sync_at = ?, file_count = ?, total_bytes = ?
		WHERE id = ? AND owner_id = ?`,
		time.Now().Unix(), fileCount, totalBytes, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteSyncedFolder removes the provenance record (the files themselves stay
// in the user's Files zone).
func (w *WriteStore) DeleteSyncedFolder(ctx context.Context, userID, id string) error {
	res, err := w.db.ExecContext(ctx,
		`DELETE FROM synced_folders WHERE id = ? AND owner_id = ?`, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}
