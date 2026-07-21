-- Sync-folder provenance (M5, foundation). A synced folder is a REAL folder in
-- the user's Files zone (users/<name>/files/<folder>/) — so it browses,
-- streams, and downloads through the existing Files service on any device.
-- This table only adds the PROVENANCE metadata the app shows in the folder's
-- info panel: which device set it syncing, when, and the last sync's tally.
--
-- Continuous bidirectional sync is deferred; this records "a device pushed this
-- folder into the vault" so every other device can reach it with full context.
CREATE TABLE synced_folders (
    id              TEXT PRIMARY KEY,          -- uuid
    owner_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,             -- display name
    rel_path        TEXT NOT NULL,             -- under the user's library (files/<name>)
    origin_device   TEXT NOT NULL DEFAULT '',  -- friendly device name that set it up
    origin_platform TEXT NOT NULL DEFAULT '',  -- ios | android | macos | windows | linux
    created_at      INTEGER NOT NULL,
    last_sync_at    INTEGER NOT NULL DEFAULT 0,
    file_count      INTEGER NOT NULL DEFAULT 0,
    total_bytes     INTEGER NOT NULL DEFAULT 0,
    UNIQUE (owner_id, rel_path)
);
CREATE INDEX idx_synced_owner ON synced_folders(owner_id, created_at DESC);
