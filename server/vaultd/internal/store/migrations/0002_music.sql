-- Music index (DESIGN: docs/MUSIC.md). One row per audio file in the user's
-- music/ zone; (size, mtime) drive incremental rescans. FTS5 mirror is kept in
-- sync by triggers so search stays correct regardless of which code path
-- mutates tracks.

CREATE TABLE tracks (
    id         TEXT PRIMARY KEY,           -- uuid
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    rel_path   TEXT NOT NULL,              -- within the user's music/ zone
    size       INTEGER NOT NULL,
    mtime      INTEGER NOT NULL,           -- unix seconds
    title      TEXT NOT NULL,
    artist     TEXT NOT NULL DEFAULT '',
    album      TEXT NOT NULL DEFAULT '',
    genre      TEXT NOT NULL DEFAULT '',
    track_no   INTEGER NOT NULL DEFAULT 0,
    year       INTEGER NOT NULL DEFAULT 0,
    has_art    INTEGER NOT NULL DEFAULT 0,
    indexed_at INTEGER NOT NULL,
    UNIQUE (user_id, rel_path)
);
CREATE INDEX idx_tracks_user ON tracks(user_id);

CREATE VIRTUAL TABLE tracks_fts USING fts5(
    title, artist, album,
    content='tracks', content_rowid='rowid'
);

CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
    INSERT INTO tracks_fts(rowid, title, artist, album)
    VALUES (new.rowid, new.title, new.artist, new.album);
END;
CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
    INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album)
    VALUES ('delete', old.rowid, old.title, old.artist, old.album);
END;
CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
    INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album)
    VALUES ('delete', old.rowid, old.title, old.artist, old.album);
    INSERT INTO tracks_fts(rowid, title, artist, album)
    VALUES (new.rowid, new.title, new.artist, new.album);
END;
