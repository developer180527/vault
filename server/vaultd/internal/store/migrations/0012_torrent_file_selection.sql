-- Which files of a torrent the user actually wants.
--
-- qBittorrent has per-file priorities, but they are a HINT, not a contract: it
-- still fetches pieces straddling a wanted/unwanted boundary, and has a long
-- history of writing unwanted files regardless. So the choice is recorded here
-- and vaultd enforces it at import time against what actually landed on disk,
-- rather than trusting the priority took.
--
-- Paths, not indices: a path is self-describing, survives a re-add, and is
-- still meaningful in a log line. Keyed by info hash, so it outlives the job.
CREATE TABLE torrent_file_selection (
    hash       TEXT PRIMARY KEY,
    keep       TEXT NOT NULL,   -- JSON array of torrent-relative paths
    updated_at INTEGER NOT NULL
);
