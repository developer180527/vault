-- Photo/video backup (M3, simple phase): each row is one original the user's
-- device backed up. Files live DATE-SHARDED under the photos root
-- (users/<username>/YYYY/MM/name.ext) as plain files — duplicating the whole
-- store is a single rsync/zfs-send of one directory. Integrity machinery
-- (content addressing, verification sweeps, 3-2-1) layers on later; the
-- sha256 recorded here is the dedupe key and the seed for that future work.
--
-- 0001 shipped a speculative photos table before the feature existed; no code
-- ever wrote to it, so replacing the empty placeholder is safe.
DROP TABLE photos;
CREATE TABLE photos (
    id          TEXT PRIMARY KEY,            -- uuid
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    rel_path    TEXT NOT NULL,               -- under users/<username>/ in the photos root
    hash        TEXT NOT NULL,               -- sha256 hex, server-computed
    size        INTEGER NOT NULL,
    mime        TEXT NOT NULL DEFAULT '',
    kind        TEXT NOT NULL DEFAULT 'photo', -- photo | video
    taken_at    INTEGER NOT NULL DEFAULT 0,  -- capture time (client EXIF), 0 unknown
    uploaded_at INTEGER NOT NULL,
    UNIQUE (user_id, hash),                  -- same bytes never stored twice per user
    UNIQUE (user_id, rel_path)
);
CREATE INDEX idx_photos_user_taken ON photos(user_id, taken_at DESC, uploaded_at DESC);
