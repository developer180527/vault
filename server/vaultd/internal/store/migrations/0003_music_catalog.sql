-- Shared music catalog (admin-curated; catalog/music/ on disk), per-user
-- playlists referencing tracks by UUID, and an append-only listen-event log.
--
-- The listen log is the ML foundation: a future recommender trains on raw
-- (user, track, when, how long) FACTS. Never store aggregates here —
-- aggregates are derivable, raw events are not.
--
-- The DB is the authoritative metadata: file tags seed it at scan, admin
-- edits win afterwards (normalization + manual fill per design).

CREATE TABLE catalog_tracks (
    id            TEXT PRIMARY KEY,           -- uuid, rename-stable
    rel_path      TEXT NOT NULL UNIQUE,       -- under catalog/music/
    size          INTEGER NOT NULL,
    mtime         INTEGER NOT NULL,           -- (size,mtime) drive rescans
    content_hash  TEXT NOT NULL DEFAULT '',
    title         TEXT NOT NULL,
    artist        TEXT NOT NULL DEFAULT '',
    album         TEXT NOT NULL DEFAULT '',
    genre         TEXT NOT NULL DEFAULT '',
    track_no      INTEGER NOT NULL DEFAULT 0,
    year          INTEGER NOT NULL DEFAULT 0,
    has_art       INTEGER NOT NULL DEFAULT 0,
    added_at      INTEGER NOT NULL
);
CREATE INDEX idx_catalog_artist ON catalog_tracks(artist);
CREATE INDEX idx_catalog_album  ON catalog_tracks(album);

-- FTS5 mirror, same trigger pattern as the per-user tracks index
-- (docs/MUSIC.md "search system"): stays in sync no matter which code path
-- mutates catalog_tracks.
CREATE VIRTUAL TABLE catalog_fts USING fts5(
    title, artist, album,
    content='catalog_tracks', content_rowid='rowid'
);
CREATE TRIGGER catalog_ai AFTER INSERT ON catalog_tracks BEGIN
    INSERT INTO catalog_fts(rowid, title, artist, album)
    VALUES (new.rowid, new.title, new.artist, new.album);
END;
CREATE TRIGGER catalog_ad AFTER DELETE ON catalog_tracks BEGIN
    INSERT INTO catalog_fts(catalog_fts, rowid, title, artist, album)
    VALUES ('delete', old.rowid, old.title, old.artist, old.album);
END;
CREATE TRIGGER catalog_au AFTER UPDATE ON catalog_tracks BEGIN
    INSERT INTO catalog_fts(catalog_fts, rowid, title, artist, album)
    VALUES ('delete', old.rowid, old.title, old.artist, old.album);
    INSERT INTO catalog_fts(rowid, title, artist, album)
    VALUES (new.rowid, new.title, new.artist, new.album);
END;

CREATE TABLE playlists (
    id         TEXT PRIMARY KEY,              -- uuid
    owner_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_playlists_owner ON playlists(owner_id);

CREATE TABLE playlist_tracks (
    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    track_id    TEXT NOT NULL REFERENCES catalog_tracks(id) ON DELETE CASCADE,
    position    INTEGER NOT NULL,
    added_at    INTEGER NOT NULL,
    PRIMARY KEY (playlist_id, track_id)
);

CREATE TABLE listens (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    track_id   TEXT NOT NULL REFERENCES catalog_tracks(id) ON DELETE CASCADE,
    started_at INTEGER NOT NULL,
    ms_played  INTEGER NOT NULL DEFAULT 0,    -- 0 = unknown (event = "started")
    source     TEXT NOT NULL DEFAULT ''       -- library | search | playlist:<id>
);
CREATE INDEX idx_listens_user  ON listens(user_id, started_at);
CREATE INDEX idx_listens_track ON listens(track_id);
