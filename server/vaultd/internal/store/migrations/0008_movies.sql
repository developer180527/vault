-- Shared movie/show catalog (M4). Mirrors catalog_music: admin-curated,
-- everyone with movies:read streams. ffprobe seeds metadata at scan; admin
-- edits win and survive rescans. Files live under the movies root
-- (catalog/movies/, the HDD pool in production).
--
-- Audio/subtitle STREAMS are stored as a JSON blob, not normalized rows: they
-- are always read together with the movie and never queried into. The client
-- reads them to build its language + subtitle pickers.
CREATE TABLE catalog_movies (
    id           TEXT PRIMARY KEY,            -- uuid, rename-stable
    rel_path     TEXT NOT NULL UNIQUE,        -- under the movies root
    size         INTEGER NOT NULL,
    mtime        INTEGER NOT NULL,            -- (size,mtime) drive rescans
    kind         TEXT NOT NULL DEFAULT 'movie', -- movie | episode
    title        TEXT NOT NULL,
    year         INTEGER NOT NULL DEFAULT 0,
    series       TEXT NOT NULL DEFAULT '',    -- '' for movies
    season       INTEGER NOT NULL DEFAULT 0,
    episode      INTEGER NOT NULL DEFAULT 0,
    overview     TEXT NOT NULL DEFAULT '',
    duration_ms  INTEGER NOT NULL DEFAULT 0,
    container    TEXT NOT NULL DEFAULT '',
    vcodec       TEXT NOT NULL DEFAULT '',
    width        INTEGER NOT NULL DEFAULT 0,
    height       INTEGER NOT NULL DEFAULT 0,
    streams      TEXT NOT NULL DEFAULT '',    -- JSON: {audio:[...], subs:[...]}
    has_art      INTEGER NOT NULL DEFAULT 0,
    added_at     INTEGER NOT NULL
);
CREATE INDEX idx_movies_series ON catalog_movies(series, season, episode);

-- FTS5 mirror over title + series, same trigger pattern as music.
CREATE VIRTUAL TABLE movies_fts USING fts5(
    title, series, content='catalog_movies', content_rowid='rowid'
);
CREATE TRIGGER movies_ai AFTER INSERT ON catalog_movies BEGIN
    INSERT INTO movies_fts(rowid, title, series)
    VALUES (new.rowid, new.title, new.series);
END;
CREATE TRIGGER movies_ad AFTER DELETE ON catalog_movies BEGIN
    INSERT INTO movies_fts(movies_fts, rowid, title, series)
    VALUES ('delete', old.rowid, old.title, old.series);
END;
CREATE TRIGGER movies_au AFTER UPDATE ON catalog_movies BEGIN
    INSERT INTO movies_fts(movies_fts, rowid, title, series)
    VALUES ('delete', old.rowid, old.title, old.series);
    INSERT INTO movies_fts(rowid, title, series)
    VALUES (new.rowid, new.title, new.series);
END;

-- Watch events (the movie twin of listens). Server keeps the LATEST position
-- per (user, movie) as the resume point — movies are long and cross-device
-- resume is the whole point, unlike music's client-side positions.
CREATE TABLE watches (
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    movie_id     TEXT NOT NULL REFERENCES catalog_movies(id) ON DELETE CASCADE,
    position_ms  INTEGER NOT NULL DEFAULT 0,
    duration_ms  INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL,
    PRIMARY KEY (user_id, movie_id)
);
CREATE INDEX idx_watches_user ON watches(user_id, updated_at DESC);
