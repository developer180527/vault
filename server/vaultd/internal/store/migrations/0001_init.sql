-- vaultd schema v1 (DESIGN.md v2.2). Identities are keyed (issuer, subject)
-- for IdP portability; grants mirror the client's CapabilityManifest.

CREATE TABLE users (
    id            TEXT PRIMARY KEY,          -- uuid
    -- OIDC identity, bound on FIRST login. Admin pre-creates users with just
    -- username+email (an invite); the first ID token whose email matches
    -- binds (issuer, subject) permanently. NULL until then.
    oidc_issuer   TEXT,
    oidc_subject  TEXT,
    username      TEXT NOT NULL UNIQUE,       -- also the library dir name
    email         TEXT UNIQUE,                -- invite binding key
    display_name  TEXT NOT NULL DEFAULT '',
    role          TEXT NOT NULL DEFAULT 'member'   -- 'admin' | 'member'
                    CHECK (role IN ('admin','member')),
    status        TEXT NOT NULL DEFAULT 'active'   -- 'active' | 'disabled'
                    CHECK (status IN ('active','disabled')),
    created_at    INTEGER NOT NULL,           -- unix seconds
    UNIQUE (oidc_issuer, oidc_subject)
);

CREATE TABLE devices (
    id             TEXT PRIMARY KEY,          -- uuid, also the client deviceId
    user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name           TEXT NOT NULL DEFAULT '',
    platform       TEXT NOT NULL DEFAULT '',
    -- Tokens stored hashed (sha256 hex). Access is short-lived and reissued
    -- via /v1/token; refresh rotates with a grace window (prev_hash valid
    -- for a short period after rotation — flaky-network double refresh).
    access_hash    TEXT NOT NULL,
    access_expires INTEGER NOT NULL DEFAULT 0,
    refresh_hash   TEXT NOT NULL,
    prev_hash      TEXT,                       -- previous token, valid in grace
    rotated_at     INTEGER NOT NULL DEFAULT 0, -- when prev_hash was superseded
    last_seen      INTEGER NOT NULL DEFAULT 0,
    created_at     INTEGER NOT NULL
);
CREATE INDEX idx_devices_user ON devices(user_id);

CREATE TABLE grants (
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    service_id  TEXT NOT NULL,
    actions     TEXT NOT NULL DEFAULT '[]',   -- JSON array, e.g. ["read","write"]
    PRIMARY KEY (user_id, service_id)
);

CREATE TABLE jobs (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL,                -- 'torrent' | 'download' | 'upload'
    source      TEXT NOT NULL,
    title       TEXT NOT NULL DEFAULT '',
    state       TEXT NOT NULL DEFAULT 'queued',
    progress    REAL NOT NULL DEFAULT 0,
    message     TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);
CREATE INDEX idx_jobs_user ON jobs(user_id);
CREATE INDEX idx_jobs_state ON jobs(state);

CREATE TABLE photos (
    id            TEXT PRIMARY KEY,
    user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content_hash  TEXT NOT NULL,              -- sha256
    original_name TEXT NOT NULL DEFAULT '',
    size          INTEGER NOT NULL DEFAULT 0,
    taken_at      INTEGER,                    -- server-extracted EXIF
    mime          TEXT NOT NULL DEFAULT '',
    rel_path      TEXT NOT NULL,
    created_at    INTEGER NOT NULL,
    -- Dedupe is per-user (privacy): a hash is unique within one user only.
    UNIQUE (user_id, content_hash)
);
CREATE INDEX idx_photos_user ON photos(user_id);
