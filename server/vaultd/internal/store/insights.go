package store

import (
	"context"
	"time"
)

// Listen analytics (ADMIN.md Phase 4). Every query aggregates the raw
// listens log at read time — no precomputed rollups to drift out of sync.

// TrackPlays is one catalog track's aggregate playback.
type TrackPlays struct {
	Title  string
	Artist string
	Plays  int
	Ms     int64
}

// ArtistPlays is one artist's aggregate playback.
type ArtistPlays struct {
	Artist string
	Plays  int
	Ms     int64
}

// ListenerStats is one member's aggregate playback.
type ListenerStats struct {
	Username string
	Plays    int
	Ms       int64
}

// DayCount is one day's listen count (day = YYYY-MM-DD, UTC).
type DayCount struct {
	Day   string
	Plays int
}

// RecentListen is one row of the live listen feed.
type RecentListen struct {
	Username string
	Title    string
	Artist   string
	Source   string
	At       int64
}

func sinceUnix(days int) int64 {
	return time.Now().AddDate(0, 0, -days).Unix()
}

// TopTracks ranks catalog tracks by play count over the last [days].
func (r *ReadStore) TopTracks(ctx context.Context, days, limit int) ([]TrackPlays, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT c.title, c.artist, COUNT(1), COALESCE(SUM(l.ms_played), 0)
		FROM listens l JOIN catalog_tracks c ON c.id = l.track_id
		WHERE l.started_at >= ?
		GROUP BY l.track_id
		ORDER BY COUNT(1) DESC, SUM(l.ms_played) DESC
		LIMIT ?`, sinceUnix(days), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TrackPlays
	for rows.Next() {
		var t TrackPlays
		if err := rows.Scan(&t.Title, &t.Artist, &t.Plays, &t.Ms); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// TopCatalogTrackIDs returns the IDs of the most-played catalog tracks over
// the last [days], most-played first. Powers the server-side warm cache
// (hottest tracks kept in RAM). Only tracks still present in the catalog are
// returned (the JOIN drops rows for deleted tracks).
func (r *ReadStore) TopCatalogTrackIDs(ctx context.Context, days, limit int) ([]string, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT l.track_id
		FROM listens l JOIN catalog_tracks c ON c.id = l.track_id
		WHERE l.started_at >= ?
		GROUP BY l.track_id
		ORDER BY COUNT(1) DESC, SUM(l.ms_played) DESC
		LIMIT ?`, sinceUnix(days), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// TopArtists ranks artists by play count over the last [days]. Combined
// credits ("A, B") count as written — the admin sees what the tags say.
func (r *ReadStore) TopArtists(ctx context.Context, days, limit int) ([]ArtistPlays, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT c.artist, COUNT(1), COALESCE(SUM(l.ms_played), 0)
		FROM listens l JOIN catalog_tracks c ON c.id = l.track_id
		WHERE l.started_at >= ? AND c.artist != ''
		GROUP BY c.artist COLLATE NOCASE
		ORDER BY COUNT(1) DESC
		LIMIT ?`, sinceUnix(days), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ArtistPlays
	for rows.Next() {
		var a ArtistPlays
		if err := rows.Scan(&a.Artist, &a.Plays, &a.Ms); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// TopListeners ranks members by plays over the last [days].
func (r *ReadStore) TopListeners(ctx context.Context, days, limit int) ([]ListenerStats, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT u.username, COUNT(1), COALESCE(SUM(l.ms_played), 0)
		FROM listens l JOIN users u ON u.id = l.user_id
		WHERE l.started_at >= ?
		GROUP BY l.user_id
		ORDER BY COUNT(1) DESC
		LIMIT ?`, sinceUnix(days), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ListenerStats
	for rows.Next() {
		var s ListenerStats
		if err := rows.Scan(&s.Username, &s.Plays, &s.Ms); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// ListensPerDay buckets listens by UTC day over the last [days].
func (r *ReadStore) ListensPerDay(ctx context.Context, days int) ([]DayCount, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT date(started_at, 'unixepoch'), COUNT(1)
		FROM listens WHERE started_at >= ?
		GROUP BY 1 ORDER BY 1`, sinceUnix(days))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DayCount
	for rows.Next() {
		var d DayCount
		if err := rows.Scan(&d.Day, &d.Plays); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// RecentListens is the newest slice of the raw event log, humanized.
func (r *ReadStore) RecentListens(ctx context.Context, limit int) ([]RecentListen, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT u.username, c.title, c.artist, l.source, l.started_at
		FROM listens l
		JOIN users u ON u.id = l.user_id
		JOIN catalog_tracks c ON c.id = l.track_id
		ORDER BY l.id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RecentListen
	for rows.Next() {
		var l RecentListen
		if err := rows.Scan(&l.Username, &l.Title, &l.Artist, &l.Source, &l.At); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// PhotoUserStats is one member's backup posture (Insights).
type PhotoUserStats struct {
	Username string
	Count    int
	Bytes    int64
	LastAt   int64
}

// PhotoBackupByUser summarizes every member's backup store, largest first.
func (r *ReadStore) PhotoBackupByUser(ctx context.Context) ([]PhotoUserStats, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT u.username, COUNT(1), COALESCE(SUM(p.size), 0),
			COALESCE(MAX(p.uploaded_at), 0)
		FROM photos p JOIN users u ON u.id = p.user_id
		GROUP BY p.user_id ORDER BY SUM(p.size) DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PhotoUserStats
	for rows.Next() {
		var s PhotoUserStats
		if err := rows.Scan(&s.Username, &s.Count, &s.Bytes, &s.LastAt); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// PhotosPerDay buckets uploads by UTC day over the last [days] — backup
// activity, the photo twin of ListensPerDay.
func (r *ReadStore) PhotosPerDay(ctx context.Context, days int) ([]DayCount, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT date(uploaded_at, 'unixepoch'), COUNT(1)
		FROM photos WHERE uploaded_at >= ?
		GROUP BY 1 ORDER BY 1`, sinceUnix(days))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DayCount
	for rows.Next() {
		var d DayCount
		if err := rows.Scan(&d.Day, &d.Plays); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// PhotosByYear counts originals by CAPTURE year ('unknown' bucket for 0) —
// how the library spreads across time.
func (r *ReadStore) PhotosByYear(ctx context.Context) ([]DayCount, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT CASE WHEN taken_at = 0 THEN 'unknown'
			ELSE strftime('%Y', taken_at, 'unixepoch') END, COUNT(1)
		FROM photos GROUP BY 1 ORDER BY 1`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DayCount
	for rows.Next() {
		var d DayCount
		if err := rows.Scan(&d.Day, &d.Plays); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// PhotoKindTotals: photos vs videos, with bytes.
func (r *ReadStore) PhotoKindTotals(ctx context.Context) (map[string]struct {
	Count int
	Bytes int64
}, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT kind, COUNT(1), COALESCE(SUM(size), 0) FROM photos GROUP BY kind`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]struct {
		Count int
		Bytes int64
	}{}
	for rows.Next() {
		var kind string
		var v struct {
			Count int
			Bytes int64
		}
		if err := rows.Scan(&kind, &v.Count, &v.Bytes); err != nil {
			return nil, err
		}
		out[kind] = v
	}
	return out, rows.Err()
}

// PhotoStatsForUser: backup posture for one member (user detail page).
func (r *ReadStore) PhotoStatsForUser(ctx context.Context, userID string) (n int, bytes, lastAt int64, err error) {
	err = r.db.QueryRowContext(ctx, `
		SELECT COUNT(1), COALESCE(SUM(size), 0), COALESCE(MAX(uploaded_at), 0)
		FROM photos WHERE user_id = ?`, userID).Scan(&n, &bytes, &lastAt)
	return n, bytes, lastAt, err
}
