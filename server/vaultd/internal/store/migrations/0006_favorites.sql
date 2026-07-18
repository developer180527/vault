-- Per-user "liked songs": a membership set over the shared catalog. One row
-- per (user, track). Deleting either side cascades the like away.
--
-- This is deliberately its OWN table, not a flag on catalog_tracks: the catalog
-- is shared and admin-owned, whereas a favorite is personal. Keeping them
-- separate is what lets every member curate their own Liked Songs over the
-- same library.
CREATE TABLE favorites (
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    track_id   TEXT NOT NULL REFERENCES catalog_tracks(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, track_id)
);
CREATE INDEX idx_favorites_user ON favorites(user_id, created_at DESC);
