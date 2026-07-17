# M3 — Server Music Streaming + Search

**Status:** design locked, building (Jul 2026). Server owns the music library;
clients stream. This doc also defines THE search system pattern that later
domains (files, photos) reuse.

## Source of truth

The user's `music/` **library zone** (`users/<name>/music/`). Files arrive by
any path — copied onto the server, a ytdlp/torrent job, later uploads. The
server never rearranges what the user put there.

## Index

SQLite `tracks` table + **FTS5** mirror, per user:

- `tracks(id, user_id, rel_path UNIQUE per user, size, mtime, title, artist,
  album, genre, track_no, year, has_art, indexed_at)`
- `tracks_fts` = FTS5 external-content table over (title, artist, album),
  kept in sync by triggers — search stays correct no matter which code path
  mutates tracks.

**Incremental scan on every listing**: stat-walk the zone (cheap at home
scale), tag-parse (dhowden/tag) only files whose (size, mtime) changed, prune
rows whose files vanished. No daemon, no staleness: the listing you get is the
disk truth. Tag-less files fall back to filename-as-title.

## Endpoints (all under `music:read`)

| Endpoint | Purpose |
|---|---|
| `GET /v1/music/tracks` | incremental scan + full listing (title/artist/album sorted) |
| `GET /v1/music/search?q=` | FTS5 match, bm25-ranked |
| `GET /v1/music/tracks/{id}/stream` | bytes via ServeContent → Range/seek free |
| `GET /v1/music/tracks/{id}/art` | embedded artwork, parsed lazily, ETag `id:mtime` |

Artwork is **not stored**: parsed from the file on request and HTTP-cached
(ETag + max-age). No blob duplication; the client's image cache does the rest.

## The search system (pattern for all domains)

- Each searchable domain owns an FTS5 table and a `Search(userID, q, limit)`
  in its service. Music is the first.
- A future unified `GET /v1/search?q=` fans out to registered domains and
  returns typed, interleaved results; the client's Cmd-K palette and per-tab
  search fields hit the same endpoint. **Domain tables now, fan-out later** —
  nothing to migrate when it lands.
- Query semantics: FTS5 prefix matching (`q*` per term), bm25 ranking.

## Client

- **Connected** → Music tab lists server tracks (search field, artwork
  thumbnails, artist/album subtitles) and streams via the central
  `PlaybackController` — `Playable(uri: https://…/stream, headers: bearer)`.
  The engine already supports network+headers; nothing changes in playback.
- **Standalone** → local files exactly as today (it's a device feature, not a
  server one).
- Search: debounced field → `/v1/music/search`; empty query → full listing.

## Known limitation (accepted for M3)

Streams carry a bearer that expires in ~15 min. The client refreshes before
building a queue, so normal listening is fine; a seek on a >15-min-old paused
stream can 401. Real fix later: short-lived signed stream URLs.
