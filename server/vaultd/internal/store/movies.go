package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
)

// jsonUnmarshal is a tiny local helper so movie rows can decode the streams
// blob without every call site importing encoding/json.
func jsonUnmarshal(s string, v any) error { return json.Unmarshal([]byte(s), v) }

// qualify prefixes every comma-separated column in [cols] with `table.`, for
// JOINs where a bare column name would be ambiguous.
func qualify(cols, table string) string {
	parts := strings.Split(cols, ",")
	for i, c := range parts {
		parts[i] = table + "." + strings.TrimSpace(c)
	}
	return strings.Join(parts, ", ")
}

// AudioStream is one selectable audio track (e.g. Japanese original, English
// dub). Index is the ffmpeg audio-stream ordinal (0-based) used for remux.
type AudioStream struct {
	Index    int    `json:"index"`
	Lang     string `json:"lang"`
	Title    string `json:"title"`
	Codec    string `json:"codec"`
	Channels int    `json:"channels"`
	Default  bool   `json:"default"`
}

// SubStream is one subtitle track. Text = convertible to WebVTT (srt/ass/
// mov_text); image subs (pgs/vobsub) can't be, and are flagged so the client
// hides them until burn-in lands. External marks a sidecar file.
type SubStream struct {
	Index    int    `json:"index"` // ffmpeg subtitle-stream ordinal (embedded)
	Lang     string `json:"lang"`
	Title    string `json:"title"`
	Codec    string `json:"codec"`
	Forced   bool   `json:"forced"`
	Text     bool   `json:"text"`     // convertible to VTT
	External string `json:"external"` // sidecar rel_path, "" if embedded
}

// MovieStreams is the JSON blob stored per movie.
type MovieStreams struct {
	Audio []AudioStream `json:"audio"`
	Subs  []SubStream   `json:"subs"`
}

// CatalogMovie is one title (movie or episode) in the shared catalog. DB
// metadata is authoritative (ffprobe seeds it; admin edits win at rescan).
type CatalogMovie struct {
	ID         string       `json:"id"`
	RelPath    string       `json:"-"`
	Size       int64        `json:"size"`
	Mtime      int64        `json:"-"`
	Kind       string       `json:"kind"`
	Title      string       `json:"title"`
	Year       int          `json:"year"`
	Series     string       `json:"series,omitempty"`
	Season     int          `json:"season,omitempty"`
	Episode    int          `json:"episode,omitempty"`
	Overview   string       `json:"overview,omitempty"`
	DurationMs int64        `json:"duration_ms"`
	Container  string       `json:"container"`
	VCodec     string       `json:"vcodec"`
	Width      int          `json:"width"`
	Height     int          `json:"height"`
	Streams    MovieStreams `json:"streams"`
	HasArt     bool         `json:"has_art"`

	// Resume position for the requesting user (transient; filled by handlers
	// from the watches table). ResumeMs 0 = start from the beginning.
	ResumeMs int64 `json:"resume_ms,omitempty"`

	// StreamURL is transient (signed, bearer-free), like music.
	StreamURL string `json:"stream_url,omitempty"`
}

// MovieKey is the scan change-detection key.
type MovieKey struct {
	ID    string
	Size  int64
	Mtime int64
}

// ExistingMovies returns rel_path → key: the scan's change baseline.
func (r *ReadStore) ExistingMovies(ctx context.Context) (map[string]MovieKey, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT rel_path, id, size, mtime FROM catalog_movies`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]MovieKey{}
	for rows.Next() {
		var rel string
		var k MovieKey
		if err := rows.Scan(&rel, &k.ID, &k.Size, &k.Mtime); err != nil {
			return nil, err
		}
		out[rel] = k
	}
	return out, rows.Err()
}

// UpsertMovie inserts or refreshes one scanned file. On refresh only FILE
// FACTS change (size/mtime/probe/streams) — never admin-owned title/series/
// overview, which survive rescans by design (music's rule).
func (w *WriteStore) UpsertMovie(ctx context.Context, m CatalogMovie, streamsJSON string) error {
	hasArt := 0
	if m.HasArt {
		hasArt = 1
	}
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO catalog_movies (id, rel_path, size, mtime, kind, title, year,
			series, season, episode, duration_ms, container, vcodec, width,
			height, streams, has_art, added_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (rel_path) DO UPDATE SET
			size=excluded.size, mtime=excluded.mtime,
			duration_ms=excluded.duration_ms, container=excluded.container,
			vcodec=excluded.vcodec, width=excluded.width, height=excluded.height,
			streams=excluded.streams, has_art=excluded.has_art`,
		uuid.NewString(), m.RelPath, m.Size, m.Mtime, m.Kind, m.Title, m.Year,
		m.Series, m.Season, m.Episode, m.DurationMs, m.Container, m.VCodec,
		m.Width, m.Height, streamsJSON, hasArt, time.Now().Unix())
	return err
}

// DeleteMovies removes rows whose files vanished.
func (w *WriteStore) DeleteMovies(ctx context.Context, ids []string) error {
	for _, id := range ids {
		if _, err := w.db.ExecContext(ctx,
			`DELETE FROM catalog_movies WHERE id = ?`, id); err != nil {
			return err
		}
	}
	return nil
}

// UpdateMovieMeta applies an admin metadata edit.
func (w *WriteStore) UpdateMovieMeta(ctx context.Context, id string, m CatalogMovie) error {
	res, err := w.db.ExecContext(ctx, `
		UPDATE catalog_movies SET title=?, year=?, series=?, season=?,
			episode=?, overview=? WHERE id=?`,
		m.Title, m.Year, m.Series, m.Season, m.Episode, m.Overview, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

const movieCols = `id, rel_path, size, mtime, kind, title, year, series,
	season, episode, overview, duration_ms, container, vcodec, width, height,
	streams, has_art`

func scanMovie(row interface{ Scan(...any) error }) (CatalogMovie, error) {
	var m CatalogMovie
	var hasArt int
	var streamsJSON string
	err := row.Scan(&m.ID, &m.RelPath, &m.Size, &m.Mtime, &m.Kind, &m.Title,
		&m.Year, &m.Series, &m.Season, &m.Episode, &m.Overview, &m.DurationMs,
		&m.Container, &m.VCodec, &m.Width, &m.Height, &streamsJSON, &hasArt)
	if err != nil {
		return m, err
	}
	m.HasArt = hasArt == 1
	if streamsJSON != "" {
		_ = jsonUnmarshal(streamsJSON, &m.Streams)
	}
	return m, nil
}

// Movies lists the whole catalog: series grouped, then movies, title-sorted.
func (r *ReadStore) Movies(ctx context.Context) ([]CatalogMovie, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+movieCols+` FROM catalog_movies
		ORDER BY series COLLATE NOCASE, season, episode,
			title COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	return collectMovies(rows)
}

// MovieByID fetches one title (shared; no user scoping).
func (r *ReadStore) MovieByID(ctx context.Context, id string) (*CatalogMovie, error) {
	row := r.db.QueryRowContext(ctx,
		`SELECT `+movieCols+` FROM catalog_movies WHERE id = ?`, id)
	m, err := scanMovie(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// SearchMovies: FTS5 prefix match over title + series, bm25-ranked.
func (r *ReadStore) SearchMovies(ctx context.Context, query string, limit int) ([]CatalogMovie, error) {
	match := ftsPrefixQuery(query)
	if match == "" {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+movieCols+` FROM catalog_movies
		WHERE rowid IN (SELECT rowid FROM movies_fts WHERE movies_fts MATCH ?)
		ORDER BY (SELECT bm25(movies_fts) FROM movies_fts
			WHERE movies_fts.rowid = catalog_movies.rowid AND movies_fts MATCH ?)
		LIMIT ?`, match, match, limit)
	if err != nil {
		return nil, err
	}
	return collectMovies(rows)
}

func collectMovies(rows *sql.Rows) ([]CatalogMovie, error) {
	defer rows.Close()
	var out []CatalogMovie
	for rows.Next() {
		m, err := scanMovie(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// --- watches (resume + Continue Watching) ---

// RecordWatch upserts the latest position for (user, movie).
func (w *WriteStore) RecordWatch(ctx context.Context, userID, movieID string, positionMs, durationMs int64) error {
	_, err := w.db.ExecContext(ctx, `
		INSERT INTO watches (user_id, movie_id, position_ms, duration_ms, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (user_id, movie_id) DO UPDATE SET
			position_ms=excluded.position_ms, duration_ms=excluded.duration_ms,
			updated_at=excluded.updated_at`,
		userID, movieID, positionMs, durationMs, time.Now().Unix())
	return err
}

// ResumeFor returns the saved position for one movie (0 if none).
func (r *ReadStore) ResumeFor(ctx context.Context, userID, movieID string) (int64, error) {
	var pos int64
	err := r.db.QueryRowContext(ctx,
		`SELECT position_ms FROM watches WHERE user_id=? AND movie_id=?`,
		userID, movieID).Scan(&pos)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return pos, err
}

// ContinueWatching returns titles the user started but hasn't finished
// (position between 30s and 95% of duration), most recent first.
func (r *ReadStore) ContinueWatching(ctx context.Context, userID string, limit int) ([]CatalogMovie, error) {
	// Qualify every movie column with the table: `duration_ms` exists on BOTH
	// catalog_movies and watches, so the bare list is ambiguous in this JOIN.
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+qualify(movieCols, "catalog_movies")+`, w.position_ms
		FROM catalog_movies
		JOIN watches w ON w.movie_id = catalog_movies.id
		WHERE w.user_id = ? AND w.position_ms > 30000
			AND (w.duration_ms = 0 OR w.position_ms < w.duration_ms * 95 / 100)
		ORDER BY w.updated_at DESC LIMIT ?`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CatalogMovie
	for rows.Next() {
		var m CatalogMovie
		var hasArt int
		var streamsJSON string
		if err := rows.Scan(&m.ID, &m.RelPath, &m.Size, &m.Mtime, &m.Kind,
			&m.Title, &m.Year, &m.Series, &m.Season, &m.Episode, &m.Overview,
			&m.DurationMs, &m.Container, &m.VCodec, &m.Width, &m.Height,
			&streamsJSON, &hasArt, &m.ResumeMs); err != nil {
			return nil, err
		}
		m.HasArt = hasArt == 1
		if streamsJSON != "" {
			_ = jsonUnmarshal(streamsJSON, &m.Streams)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// CountMovies is the admin System/Insights count.
func (r *ReadStore) CountMovies(ctx context.Context) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(1) FROM catalog_movies`).Scan(&n)
	return n, err
}
