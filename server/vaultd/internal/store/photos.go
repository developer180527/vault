package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Photo is one backed-up original (photo or video) in a user's photo zone.
type Photo struct {
	ID         string `json:"id"`
	RelPath    string `json:"-"`
	Hash       string `json:"hash"`
	Size       int64  `json:"size"`
	Mime       string `json:"mime"`
	Kind       string `json:"kind"` // photo | video
	TakenAt    int64  `json:"taken_at"`
	UploadedAt int64  `json:"uploaded_at"`
	Name       string `json:"name"` // display name (base of rel_path)

	// HasThumb is TRANSIENT (never stored): stat'ed against the thumbs dir
	// by the list handler so the client knows which grid cells can load.
	HasThumb bool `json:"has_thumb"`
}

// InsertPhoto records one uploaded original.
func (w *WriteStore) InsertPhoto(ctx context.Context, userID string, p Photo) (string, error) {
	id := uuid.NewString()
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO photos (id, user_id, rel_path, hash, size, mime, kind,
			taken_at, uploaded_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, userID, p.RelPath, p.Hash, p.Size, p.Mime, p.Kind,
		p.TakenAt, time.Now().Unix())
	return id, err
}

const photoCols = `id, rel_path, hash, size, mime, kind, taken_at, uploaded_at`

func scanPhoto(row interface{ Scan(...any) error }) (Photo, error) {
	var p Photo
	err := row.Scan(&p.ID, &p.RelPath, &p.Hash, &p.Size, &p.Mime, &p.Kind,
		&p.TakenAt, &p.UploadedAt)
	if i := strings.LastIndexByte(p.RelPath, '/'); i >= 0 {
		p.Name = p.RelPath[i+1:]
	} else {
		p.Name = p.RelPath
	}
	return p, err
}

// PhotosForUser lists a user's backed-up originals, newest capture first
// (unknown capture times sort by upload time via the index's second key).
func (r *ReadStore) PhotosForUser(ctx context.Context, userID string, limit, offset int) ([]Photo, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+photoCols+` FROM photos WHERE user_id = ?
		ORDER BY taken_at DESC, uploaded_at DESC LIMIT ? OFFSET ?`,
		userID, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Photo
	for rows.Next() {
		p, err := scanPhoto(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// PhotoByID fetches one photo, owner-scoped — no cross-user access, ever.
func (r *ReadStore) PhotoByID(ctx context.Context, userID, id string) (*Photo, error) {
	row := r.db.QueryRowContext(ctx,
		`SELECT `+photoCols+` FROM photos WHERE id = ? AND user_id = ?`, id, userID)
	p, err := scanPhoto(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

// PhotoByHash returns the user's photo with this content hash, if backed up.
func (r *ReadStore) PhotoByHash(ctx context.Context, userID, hash string) (*Photo, error) {
	row := r.db.QueryRowContext(ctx,
		`SELECT `+photoCols+` FROM photos WHERE user_id = ? AND hash = ?`, userID, hash)
	p, err := scanPhoto(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

// ExistingPhotoHashes filters [hashes] down to the ones this user already has
// — the server side of the client's "what's missing?" pre-upload check.
// Chunked IN queries keep it inside SQLite's bound-parameter limit.
func (r *ReadStore) ExistingPhotoHashes(ctx context.Context, userID string, hashes []string) (map[string]bool, error) {
	out := map[string]bool{}
	const chunk = 500
	for start := 0; start < len(hashes); start += chunk {
		end := min(start+chunk, len(hashes))
		part := hashes[start:end]
		args := make([]any, 0, len(part)+1)
		args = append(args, userID)
		ph := make([]string, len(part))
		for i, h := range part {
			ph[i] = "?"
			args = append(args, h)
		}
		rows, err := r.db.QueryContext(ctx, `
			SELECT hash FROM photos WHERE user_id = ? AND hash IN (`+
			strings.Join(ph, ",")+`)`, args...)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var h string
			if err := rows.Scan(&h); err != nil {
				rows.Close()
				return nil, err
			}
			out[h] = true
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, err
		}
		rows.Close()
	}
	return out, nil
}

// CountPhotos returns a user's backed-up count and total bytes.
func (r *ReadStore) CountPhotos(ctx context.Context, userID string) (n int, bytes int64, err error) {
	err = r.db.QueryRowContext(ctx, `
		SELECT COUNT(1), COALESCE(SUM(size), 0) FROM photos WHERE user_id = ?`,
		userID).Scan(&n, &bytes)
	return n, bytes, err
}

// PhotoFile is the minimum needed to check a stored original against disk.
type PhotoFile struct {
	ID       string
	Username string
	RelPath  string
	Size     int64
}

// AllPhotoFiles lists every stored original with its owner, for integrity
// checks (does the file the DB promises actually exist?).
func (r *ReadStore) AllPhotoFiles(ctx context.Context) ([]PhotoFile, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT p.id, u.username, p.rel_path, p.size
		FROM photos p JOIN users u ON u.id = p.user_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PhotoFile
	for rows.Next() {
		var f PhotoFile
		if err := rows.Scan(&f.ID, &f.Username, &f.RelPath, &f.Size); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// CountAllPhotos totals the whole backup store — the admin System card.
func (r *ReadStore) CountAllPhotos(ctx context.Context) (n int, bytes int64, err error) {
	err = r.db.QueryRowContext(ctx,
		`SELECT COUNT(1), COALESCE(SUM(size), 0) FROM photos`).Scan(&n, &bytes)
	return n, bytes, err
}
