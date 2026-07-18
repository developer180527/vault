package store

import (
	"context"
	"encoding/json"
)

// Known service ids and actions — the server-side mirror of the client's
// registry and CapabilityAction enum. Grants for unknown ids are rejected at
// the CLI/API edge so typos don't silently grant nothing.
var (
	KnownServices = []string{"media", "files", "music", "photos", "torrent", "downloads", "chat"}
	// Keep in lockstep with the client's CapabilityAction enum.
	// `sync` gates the heavy backup/sync engine, distinct from plain write
	// (see DESIGN.md "The library directory vs the Files service").
	KnownActions = []string{"read", "write", "delete", "stream", "share", "sync", "admin"}
)

// SetGrant upserts one user's actions for a service.
func (w *WriteStore) SetGrant(ctx context.Context, userID, serviceID string, actions []string) error {
	blob, err := json.Marshal(actions)
	if err != nil {
		return err
	}
	_, err = w.db.ExecContext(ctx, `
		INSERT INTO grants (user_id, service_id, actions) VALUES (?, ?, ?)
		ON CONFLICT (user_id, service_id) DO UPDATE SET actions = excluded.actions`,
		userID, serviceID, string(blob))
	return err
}

// RemoveGrant revokes a service entirely for a user.
func (w *WriteStore) RemoveGrant(ctx context.Context, userID, serviceID string) error {
	_, err := w.db.ExecContext(ctx,
		`DELETE FROM grants WHERE user_id = ? AND service_id = ?`, userID, serviceID)
	return err
}

// GrantsForUser returns serviceID → actions.
func (r *ReadStore) GrantsForUser(ctx context.Context, userID string) (map[string][]string, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT service_id, actions FROM grants WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][]string{}
	for rows.Next() {
		var svc, blob string
		if err := rows.Scan(&svc, &blob); err != nil {
			return nil, err
		}
		var actions []string
		if err := json.Unmarshal([]byte(blob), &actions); err != nil {
			return nil, err
		}
		out[svc] = actions
	}
	return out, rows.Err()
}
