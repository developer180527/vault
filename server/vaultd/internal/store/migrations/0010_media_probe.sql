-- Cached ffprobe results for arbitrary files (the Files service). Movies are
-- probed at scan and stored on the row; ANY other video has to be probed on
-- demand, and probing a 12 GB file on a cold HDD is slow enough that repeating
-- it per playback would be felt.
--
-- The key embeds size+mtime — the same change-detection pair the scanners use
-- — so replacing a file's bytes invalidates its entry automatically and there
-- is nothing to expire by hand.
CREATE TABLE media_probe (
    cache_key TEXT PRIMARY KEY,   -- "<user>|<rel_path>|<size>|<mtime>"
    info      TEXT NOT NULL,      -- JSON: container/vcodec/dims/duration/streams
    probed_at INTEGER NOT NULL
);
CREATE INDEX idx_media_probe_at ON media_probe(probed_at);
