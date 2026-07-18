package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
)

// CatalogTrack is one track in the SHARED, admin-curated music catalog. The
// DB metadata is authoritative (tags seed it at scan; admin edits win).
type CatalogTrack struct {
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

// Playlist is a user-owned ordered set of catalog track UUIDs.
type Playlist struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	TrackCount int    `json:"track_count"`
}

// ExistingCatalogTracks returns rel_path → key: the scan's change baseline.
func (r *ReadStore) ExistingCatalogTracks(ctx context.Context) (map[string]TrackKey, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT rel_path, id, size, mtime FROM catalog_tracks`)
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

// UpsertCatalogTrack inserts or refreshes one scanned file. On refresh the
// scan only updates file facts (size/mtime/art) — NOT title/artist/album/
// genre, because admin edits to those must survive rescans. Fresh inserts
// take the tag-derived metadata.
func (w *WriteStore) UpsertCatalogTrack(ctx context.Context, t CatalogTrack) error {
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO catalog_tracks (id, rel_path, size, mtime, title, artist,
			album, genre, track_no, year, has_art, added_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (rel_path) DO UPDATE SET
			size = excluded.size, mtime = excluded.mtime,
			has_art = excluded.has_art`,
		uuid.NewString(), t.RelPath, t.Size, t.Mtime, t.Title, t.Artist,
		t.Album, t.Genre, t.TrackNo, t.Year, t.HasArt, time.Now().Unix())
	return err
}

// DeleteCatalogTracks removes rows whose files vanished.
func (w *WriteStore) DeleteCatalogTracks(ctx context.Context, ids []string) error {
	for _, id := range ids {
		if _, err := w.db.ExecContext(ctx,
			`DELETE FROM catalog_tracks WHERE id = ?`, id); err != nil {
			return err
		}
	}
	return nil
}

// UpdateCatalogMeta applies an admin metadata edit (normalize/manual fill).
func (w *WriteStore) UpdateCatalogMeta(ctx context.Context, id string, t CatalogTrack) error {
	res, err := w.db.ExecContext(ctx, `
		UPDATE catalog_tracks SET title=?, artist=?, album=?, genre=?,
			track_no=?, year=? WHERE id=?`,
		t.Title, t.Artist, t.Album, t.Genre, t.TrackNo, t.Year, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

const catalogCols = `id, rel_path, size, mtime, title, artist, album, genre,
	track_no, year, has_art`

func scanCatalogTrack(rows interface{ Scan(...any) error }) (CatalogTrack, error) {
	var t CatalogTrack
	var hasArt int
	err := rows.Scan(&t.ID, &t.RelPath, &t.Size, &t.Mtime, &t.Title, &t.Artist,
		&t.Album, &t.Genre, &t.TrackNo, &t.Year, &hasArt)
	t.HasArt = hasArt == 1
	return t, err
}

// CatalogTracks lists the whole catalog, artist → album → track order.
func (r *ReadStore) CatalogTracks(ctx context.Context) ([]CatalogTrack, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+catalogCols+` FROM catalog_tracks
		ORDER BY artist COLLATE NOCASE, album COLLATE NOCASE, track_no, title COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	return collectCatalog(rows)
}

// CatalogTrackByID fetches one catalog track (shared: no user scoping).
func (r *ReadStore) CatalogTrackByID(ctx context.Context, id string) (*CatalogTrack, error) {
	row := r.db.QueryRowContext(ctx,
		`SELECT `+catalogCols+` FROM catalog_tracks WHERE id = ?`, id)
	t, err := scanCatalogTrack(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// SearchCatalog: FTS5 prefix match over the shared catalog, bm25-ranked —
// the catalog domain of THE search system (docs/MUSIC.md).
func (r *ReadStore) SearchCatalog(ctx context.Context, query string, limit int) ([]CatalogTrack, error) {
	match := ftsPrefixQuery(query)
	if match == "" {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+catalogCols+` FROM catalog_tracks
		WHERE rowid IN (SELECT rowid FROM catalog_fts WHERE catalog_fts MATCH ?)
		ORDER BY (SELECT bm25(catalog_fts) FROM catalog_fts
			WHERE catalog_fts.rowid = catalog_tracks.rowid AND catalog_fts MATCH ?)
		LIMIT ?`,
		match, match, limit)
	if err != nil {
		return nil, err
	}
	return collectCatalog(rows)
}

func collectCatalog(rows *sql.Rows) ([]CatalogTrack, error) {
	defer rows.Close()
	var out []CatalogTrack
	for rows.Next() {
		t, err := scanCatalogTrack(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// --- playlists (per-user, tracks by UUID) ---

// PlaylistsForUser lists a user's playlists with track counts.
func (r *ReadStore) PlaylistsForUser(ctx context.Context, userID string) ([]Playlist, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT p.id, p.name, COUNT(pt.track_id)
		FROM playlists p
		LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id
		WHERE p.owner_id = ?
		GROUP BY p.id ORDER BY p.created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Playlist
	for rows.Next() {
		var p Playlist
		if err := rows.Scan(&p.ID, &p.Name, &p.TrackCount); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// CreatePlaylist makes an empty playlist for a user.
func (w *WriteStore) CreatePlaylist(ctx context.Context, userID, name string) (*Playlist, error) {
	p := &Playlist{ID: uuid.NewString(), Name: name}
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO playlists (id, owner_id, name, created_at) VALUES (?, ?, ?, ?)`,
		p.ID, userID, name, time.Now().Unix())
	if err != nil {
		return nil, err
	}
	return p, nil
}

// playlistOwned verifies ownership; ErrNotFound otherwise (no cross-user
// playlist access, ever).
func (r *ReadStore) playlistOwned(ctx context.Context, userID, playlistID string) error {
	var n int
	if err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM playlists WHERE id = ? AND owner_id = ?`,
		playlistID, userID).Scan(&n); err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// PlaylistTracks lists a playlist's tracks in position order (owner-scoped).
func (r *ReadStore) PlaylistTracks(ctx context.Context, userID, playlistID string) ([]CatalogTrack, error) {
	if err := r.playlistOwned(ctx, userID, playlistID); err != nil {
		return nil, err
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+catalogCols+` FROM catalog_tracks
		JOIN playlist_tracks pt ON pt.track_id = catalog_tracks.id
		WHERE pt.playlist_id = ? ORDER BY pt.position`, playlistID)
	if err != nil {
		return nil, err
	}
	return collectCatalog(rows)
}

// DeletePlaylist removes a playlist the user owns.
func (w *WriteStore) DeletePlaylist(ctx context.Context, userID, playlistID string) error {
	res, err := w.db.ExecContext(ctx,
		`DELETE FROM playlists WHERE id = ? AND owner_id = ?`, playlistID, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// AddToPlaylist appends a track (idempotent; keeps first position).
func (w *WriteStore) AddToPlaylist(ctx context.Context, userID, playlistID, trackID string) error {
	// Ownership check on the write connection's view is fine — reads are safe.
	var n int
	if err := w.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM playlists WHERE id = ? AND owner_id = ?`,
		playlistID, userID).Scan(&n); err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at)
		VALUES (?, ?,
			(SELECT COALESCE(MAX(position), 0) + 1 FROM playlist_tracks WHERE playlist_id = ?),
			?)
		ON CONFLICT (playlist_id, track_id) DO NOTHING`,
		playlistID, trackID, playlistID, time.Now().Unix())
	return err
}

// RemoveFromPlaylist drops one track from an owned playlist.
func (w *WriteStore) RemoveFromPlaylist(ctx context.Context, userID, playlistID, trackID string) error {
	res, err := w.db.ExecContext(ctx, `
		DELETE FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?
			AND playlist_id IN (SELECT id FROM playlists WHERE owner_id = ?)`,
		playlistID, trackID, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// --- listens (ML event log) ---

// InsertListen appends one raw listen event.
func (w *WriteStore) InsertListen(ctx context.Context, userID, trackID string, msPlayed int, source string) error {
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO listens (user_id, track_id, started_at, ms_played, source)
		VALUES (?, ?, ?, ?, ?)`,
		userID, trackID, time.Now().Unix(), msPlayed, source)
	return err
}
