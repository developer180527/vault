package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Track is one indexed audio file in a user's music zone (docs/MUSIC.md).
type Track struct {
	ID      string `json:"id"`
	RelPath string `json:"-"`
	Size    int64  `json:"size"`
	Mtime   int64  `json:"-"`
	Title   string `json:"title"`
	Artist  string `json:"artist"`
	Album   string `json:"album"`
	Genre   string `json:"genre"`
	TrackNo int    `json:"track_no"`
	Year    int    `json:"year"`
	HasArt  bool   `json:"has_art"`

	// StreamURL is TRANSIENT (never stored): a signed, bearer-free
	// stream path attached by the list handlers so playback outlives
	// the 15-minute access token (docs/MUSIC.md, auth.StreamSigner).
	StreamURL string `json:"stream_url,omitempty"`
}

// TrackKey is what an incremental scan needs to decide "unchanged, skip".
type TrackKey struct {
	ID    string
	Size  int64
	Mtime int64
}

// ExistingTracks returns rel_path → key for one user, in one query — the
// scan's change-detection baseline.
func (r *ReadStore) ExistingTracks(ctx context.Context, userID string) (map[string]TrackKey, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT rel_path, id, size, mtime FROM tracks WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]TrackKey{}
	for rows.Next() {
		var rel string
		var k TrackKey
		if err := rows.Scan(&rel, &k.ID, &k.Size, &k.Mtime); err != nil {
			return nil, err
		}
		out[rel] = k
	}
	return out, rows.Err()
}

// UpsertTrack inserts or refreshes one indexed file (keyed user+rel_path).
func (w *WriteStore) UpsertTrack(ctx context.Context, userID string, t Track) error {
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO tracks (id, user_id, rel_path, size, mtime, title, artist,
			album, genre, track_no, year, has_art, indexed_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (user_id, rel_path) DO UPDATE SET
			size = excluded.size, mtime = excluded.mtime,
			title = excluded.title, artist = excluded.artist,
			album = excluded.album, genre = excluded.genre,
			track_no = excluded.track_no, year = excluded.year,
			has_art = excluded.has_art, indexed_at = excluded.indexed_at`,
		uuid.NewString(), userID, t.RelPath, t.Size, t.Mtime, t.Title, t.Artist,
		t.Album, t.Genre, t.TrackNo, t.Year, t.HasArt, time.Now().Unix())
	return err
}

// DeleteTracks removes rows whose files vanished from disk.
func (w *WriteStore) DeleteTracks(ctx context.Context, ids []string) error {
	for _, id := range ids { // home scale; no need for batched IN
		if _, err := w.db.ExecContext(ctx,
			`DELETE FROM tracks WHERE id = ?`, id); err != nil {
			return err
		}
	}
	return nil
}

const trackCols = `id, rel_path, size, mtime, title, artist, album, genre,
	track_no, year, has_art`

func scanTrack(rows interface{ Scan(...any) error }) (Track, error) {
	var t Track
	var hasArt int
	err := rows.Scan(&t.ID, &t.RelPath, &t.Size, &t.Mtime, &t.Title, &t.Artist,
		&t.Album, &t.Genre, &t.TrackNo, &t.Year, &hasArt)
	t.HasArt = hasArt == 1
	return t, err
}

// TracksForUser lists the whole library, artist → album → track order.
func (r *ReadStore) TracksForUser(ctx context.Context, userID string) ([]Track, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+trackCols+` FROM tracks WHERE user_id = ?
		ORDER BY artist COLLATE NOCASE, album COLLATE NOCASE, track_no, title COLLATE NOCASE`,
		userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// TrackByID fetches one track, scoped to its owner (no cross-user reads).
func (r *ReadStore) TrackByID(ctx context.Context, userID, id string) (*Track, error) {
	row := r.db.QueryRowContext(ctx, `
		SELECT `+trackCols+` FROM tracks WHERE id = ? AND user_id = ?`, id, userID)
	t, err := scanTrack(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// SearchTracks runs an FTS5 prefix query over title/artist/album, bm25-ranked.
// This is the music domain of THE search system (docs/MUSIC.md): each domain
// owns an FTS table + a Search function; a unified /v1/search fans out later.
func (r *ReadStore) SearchTracks(ctx context.Context, userID, query string, limit int) ([]Track, error) {
	match := ftsPrefixQuery(query)
	if match == "" {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+trackCols+` FROM tracks
		WHERE rowid IN (SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH ?)
			AND user_id = ?
		ORDER BY (SELECT bm25(tracks_fts) FROM tracks_fts
			WHERE tracks_fts.rowid = tracks.rowid AND tracks_fts MATCH ?)
		LIMIT ?`,
		match, userID, match, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// ftsPrefixQuery turns free text into a safe FTS5 query: each term quoted
// (neutralizing operator syntax) with prefix matching, AND-ed together.
func ftsPrefixQuery(q string) string {
	terms := strings.Fields(q)
	parts := make([]string, 0, len(terms))
	for _, t := range terms {
		t = strings.ReplaceAll(t, `"`, `""`)
		parts = append(parts, `"`+t+`"*`)
	}
	return strings.Join(parts, " ")
}
