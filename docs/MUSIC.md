# M3 — Server Music Streaming + Search

**Status:** per-user zone shipped; shared catalog shipped (Jul 2026). Server
owns the music libraries; clients stream. This doc also defines THE search
system pattern that later domains (files, photos) reuse.

Two libraries share the music service:

1. **Per-user zone** (`users/<name>/music/`) — the original design below,
   unchanged, additive-compatible.
2. **Shared catalog** (`catalog/music/`) — admin-curated, everyone streams.
   See "The shared catalog" at the end.

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

## Known limitation (accepted for M3) — FIXED via signed stream URLs

Streams originally carried a bearer that expires in ~15 min, so loop
restarts, queue wraps, and late seeks 401'd mid-listen. Fixed: list
endpoints now attach a per-track `stream_url` — a signed path
(`?u=&exp=&sig=`, HMAC over track identity + expiry, key generated at
`system/stream_signing_key`, 24h TTL). Stream endpoints sit outside the
auth middleware and accept a valid signature OR the bearer+grant path
(compat for old clients). The signed URL is the capability: leaking one
leaks one track for a bounded time. Clients prefer `stream_url` when
present and fall back to the bearer route against old servers.

## Streaming performance (native path + warm cache)

Three things keep server audio feeling instant rather than sluggish:

1. **Bearer-free (native) streaming — the big one.** just_audio can't set
   request headers on iOS/macOS, so passing `headers:` to `AudioSource.uri`
   makes it spin up a **localhost header-injection proxy** that fetches the
   origin on the player's behalf — and that proxy, not vaultd, was serializing
   Range and stalling playback. The signed `stream_url` needs no headers, so
   the client now hands the player a **bare** signed URL (`Playable.headers`
   empty) and AVPlayer/ExoPlayer stream the origin **directly** with real
   Range/206. Artwork keeps its own bearer via `Playable.artHeaders` (a
   separate field) so lock-screen art still loads. Because a bare source can't
   fall through to a bearer, a >24h-stale signature would 401 — so the player
   fetches a **fresh** signed URL (`GET /v1/music/{tracks,catalog}/{id}/stream-url`)
   and retries **once** before surfacing failure (`Playable.refreshUri`). No
   silent drop, no proxy.

2. **`+faststart`.** Uploaded `.m4a/.mp4` can carry their `moov` atom after the
   media, forcing a player to fetch the tail before it can start. `POST
   /v1/music/catalog/optimize` (admin, music:write, also a button on the
   catalog page) detects that layout with a cheap top-level atom walk (no
   ffprobe) and rewrites `-c copy -movflags +faststart` in place, atomically.
   Lossless and idempotent — a second run is all skips.

3. **Warm RAM cache.** The household's top-N most-played catalog tracks (from
   the listen analytics, `TopCatalogTrackIDs`, default N=5) are held in memory
   and served with `http.ServeContent` — full Range/206 from RAM, zero disk
   I/O — so the songs everyone replays start instantly. Refreshed on a 15-min
   ticker; a miss just falls back to `ServeFile`, so it's a pure accelerator
   with no correctness impact. Capped at 32 MB/track (songs are ~5–12 MB).

**What was already fine (measured, not assumed):** the backend already serves
206/`Accept-Ranges` via `ServeFile`/`ServeContent`, no compression middleware
strips it, and Caddy has no `encode` directive — Range passes clean through
tailscale serve. HTTP/2 and keep-alive live at tailscale serve. So the fix was
the client proxy + file layout, not the transport.

## The shared catalog (migration 0003)

**Ownership model:** the music service owns `catalog/music/` — no user library
zone, no client path surface, tracks are addressed only by UUID. Only the
admin loads files (drop into the directory, then scan) or edits metadata;
every user holding `music:read` streams and searches it.

**Schema:** `catalog_tracks` (uuid PK, rel_path UNIQUE, file facts + metadata)
with a `catalog_fts` FTS5 mirror (same trigger pattern as `tracks_fts`);
`playlists` (uuid, owner uuid, name) + `playlist_tracks` (position-ordered
track uuids); `listens` — append-only `(user, track, started_at, ms_played,
source)` event log.

**Scan is explicit, not per-listing** (unlike the per-user zone): the catalog
only changes when the admin loads music, so listings stay a pure DB read at
any size. `POST /v1/music/catalog/scan` (music:write) or
`docker compose exec vaultd vaultdctl music scan`. Same incremental
size+mtime walk, same dhowden/tag parse, filename-fallback titles.

**DB is the authoritative metadata:** tags seed a row on first scan; rescans
refresh only file facts (size/mtime/has_art). Admin edits via
`PATCH /v1/music/catalog/{id}` (partial JSON: title/artist/album/genre/
track_no/year) therefore survive rescans, and FTS triggers keep search in
sync with edits. Track UUIDs are stable across rescans and admin renames of
metadata (rel_path is the identity key on disk).

**Endpoints** (additive to /v1; per-user routes untouched):

| Endpoint | Grant | Purpose |
|---|---|---|
| `GET /v1/music/catalog?q=` | music:read | full list (artist/album/track order) or FTS search |
| `GET /v1/music/catalog/{id}/stream` | music:read | Range-capable bytes |
| `GET /v1/music/catalog/{id}/art` | music:read | lazy artwork, ETag |
| `PATCH /v1/music/catalog/{id}` | music:write | admin metadata edit |
| `POST /v1/music/catalog/scan` | music:write | index the drop directory |
| `GET/POST /v1/music/playlists` | music:read | list / create (owner-scoped) |
| `DELETE /v1/music/playlists/{id}` | music:read | delete own playlist |
| `GET/POST /v1/music/playlists/{id}/tracks` | music:read | contents / add `{track_id}` |
| `DELETE /v1/music/playlists/{id}/tracks/{trackId}` | music:read | remove |
| `POST /v1/music/listens` | music:read | `{track_id, source, ms_played?}` |

Playlists are strictly owner-scoped in the store (cross-user access is a 404,
even for admins). Adding validates the track uuid; deleting a catalog track
cascades out of playlists and keeps the event log FK-clean.

**ML-readiness:** recommendations need raw facts, so `listens` records one
row per play — user uuid, track uuid, when, how long, and where it started
(`library` | `search` | `playlist:<id>`). Never aggregates: those are
derivable later; raw events are not. Track uuids are rename-stable, metadata
is normalized/admin-corrected in the DB — exactly the joins a future
recommender trains on. The client reports listens fire-and-forget (playback
never stalls on telemetry).

**Client:** connected Music tab shows source chips — **Catalog** (default),
**My music** (per-user zone), the user's playlists, and "New playlist". One
search field serves all sources (catalog/personal search server-side,
playlist contents filtered client-side). Long-press a catalog track to add
it to a playlist; long-press a playlist track to remove it; long-press a
playlist chip to delete it. Playback flows through the same
`PlaybackController` with catalog stream URIs + bearer headers.

**Deploy/admin flow:** vaultd creates `/srv/vault/catalog/music` at boot;
copy music there (any folder structure), run
`docker compose exec vaultd vaultdctl music scan`, done — every music:read
member sees it immediately.
