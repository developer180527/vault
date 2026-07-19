# M4 — Movie & Show Streaming

**Status:** design (Jul 2026). Mirrors the music service deliberately — the
signed-URL streaming, catalog-scan, and central-playback machinery music
built IS the movie machinery; this doc mostly maps names. Read
`docs/MUSIC.md` first.

## What music already proved (reused as-is)

| Music piece | Movies reuse |
|---|---|
| Shared catalog zone (`catalog/music/`) + incremental scan | `catalog/movies/` + same stat-walk scan |
| DB-authoritative metadata (tags seed, admin edits win) | identical (`ffprobe` seeds instead of ID3 tags) |
| Signed stream URLs (`auth.StreamSigner`, 24h HMAC, bearer fallback) | same signer, `stream:movie:<id>` payload |
| `http.ServeFile` Range/seek streaming | identical — video IS range requests |
| Single-source central playback (`PlaybackController`) | already video-shaped: `openVideoPlayback(Playable)` |
| Resume positions (`playbackPositionStore`, client-side) | already works for any Playable id |
| Grant model (`music:read` / `music:write`) | new service `movies`: read streams, write curates |
| Admin panel catalog manager (upload/edit/trash) | same pages, movies flavor |
| Listen events (`listens`) | `watches` events (raw facts, ML later) |

## Source of truth

`catalog/movies/` — admin-curated, shared, like the music catalog. Files
arrive by disk copy, torrent/ytdlp job hand-off, or admin-panel upload.
Optional per-user zone (`users/<name>/videos/`) can come later; the shared
catalog is the product.

Layout stays human/rsync-first (the photos rule): plain video files, optional
one-level folders (`Movies/`, `Shows/<name>/Season 1/`). Dot-dirs are
service-internal (`.trash/`, `.art/` for posters — same conventions as
music).

## Index

`catalog_movies` table + FTS5 mirror, same trigger pattern:

```
catalog_movies(id uuid, rel_path UNIQUE, size, mtime,
    title, year, kind photo|episode?  -- 'movie' | 'episode'
    series, season, episode,          -- empty for movies
    duration_ms, container, vcodec, acodec, width, height,
    has_art, added_at)
```

- **Scan** = walk + `ffprobe -print_format json` (ffmpeg already in the
  container) for new/changed files only. Filename conventions seed
  title/year/series/season/episode (`Movie (2019).mkv`,
  `Show/S01E03 - Name.mkv`); admin edits win and survive rescans, exactly
  like music.
- Codec/container columns are recorded at scan so the CLIENT can decide
  direct-play vs transcode without probing the file again.

## Streaming: direct-play first, HLS only when needed

**Phase A (ship first): direct play.** `GET /v1/movies/{id}/stream` —
signed-URL or bearer, `http.ServeFile`, byte-range seeking. mp4/h264/aac
direct-plays everywhere; most mkv/hevc plays on modern devices. The client
already has `planPlayback(MediaTrack, support)` (media_codec.dart) deciding
direct vs transcode — wire it to the probed codec columns.

**Phase B: on-demand HLS transcode** for what can't direct-play (the Ryzen
2600X does software x264 ~1 realtime for 1080p — one stream at a time,
acceptable at household scale):

- `GET /v1/movies/{id}/hls/master.m3u8` → starts/joins an ffmpeg session
  (`-c:v libx264 -preset veryfast` only when vcodec unsupported, else
  `-c:v copy` remux — remux covers the common "mkv container, h264 inside"
  case at ~zero CPU).
- Sessions: one per (movie), idle-killed after 60s unwatched, segments in
  `system/transcode/<id>/` (tmpfs-sized, GC'd). Seek = new session at offset.
- Signed-URL auth on every playlist/segment request (same signer).

**Explicitly rejected:** transcoding everything (CPU death), and building a
Plex-grade profile matrix. Direct play + one fallback ladder is the whole
story at home scale.

## Endpoints

| Endpoint | Grant | Purpose |
|---|---|---|
| `GET /v1/movies` (`?q=`) | movies:read | listing / FTS search, signed stream URLs attached |
| `GET /v1/movies/{id}/stream` | signed or movies:read | direct-play bytes, Range |
| `GET /v1/movies/{id}/art` | movies:read | poster (`.art/<id>.img` override wins, else embedded/`folder.jpg`), ETag'd |
| `POST /v1/movies/{id}/watches` | movies:read | `{position_ms, duration_ms}` raw watch events; server keeps latest as resume point |
| `GET /v1/movies/continue` | movies:read | resume shelf (latest unfinished per title) |
| `PATCH /v1/movies/{id}` | movies:write | admin metadata edit |
| `POST /v1/movies/scan` | movies:write | admin rescan |
| *(Phase B)* `GET /v1/movies/{id}/hls/*` | signed | transcode/remux sessions |

Server-side resume (unlike music's client-only positions) because movies are
long and cross-device resume is the point: watch events land in a `watches`
table; `continue` derives the shelf.

## Client

- New `movies` service tab (manifest-gated), browse: poster grid, Continue
  Watching shelf on top, search field — same section pattern as Music.
- Playback: `openVideoPlayback(Playable)` **unchanged** — network Playable
  with signed URL. Resume prompt from server position. Report watch progress
  every ~30s + on pause/close (fire-and-forget like listens).
- Codec plan: probed columns + `planPlayback` → direct URL or (Phase B) HLS
  URL. No client probing.

## Admin

- Catalog manager clone: upload (big files — the job pipeline's staging mount
  is the better path for >4GB; panel upload capped), metadata edit
  (title/year/series/season/episode), poster override, trash-delete.
- Insights: watches/day, top titles, per-member viewing — same bar pattern.

## Build order

1. **Server Phase A** (one session): migration, scan+ffprobe, list/search/
   stream/art/watches/continue, `movies` in KnownServices, tests. ~mirrors
   the music catalog diff.
2. **Client** (one session): Movies tab (grid + continue shelf + search),
   playback wiring with resume + progress reporting.
3. **Admin** catalog pages (half session).
4. **Phase B HLS** when a file that won't direct-play actually annoys someone
   — not before.
