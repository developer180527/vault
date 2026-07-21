# Movies — Shared Video Catalog

Status: **Phase A shipped** (catalog + direct-play + audio/subtitle switching
via zero-CPU remux). Phase B (real transcode for incompatible codecs) is
designed but not built — see the end. This doc is written retroactively from
the shipped code; treat it as the spec of record.

Movies deliberately **mirror the music catalog** (docs/MUSIC.md): admin-curated,
shared, `movies:read` streams / `movies:write` administers, signed stream URLs,
snapshot-first client cache, FTS5 search. The differences are all downstream of
one fact: **video files are big, multi-track, and long.**

## Source of truth

`catalog/movies/` on disk — in production its own ZFS dataset
(`vaultdata/movies` mounted at `/srv/vault/movies`), kept separate from the
`users/` photo/file boundary so rsync/scp workflows don't cross. Files arrive
by scp/rsync (fast, resumable) or the admin-panel browser upload (streamed to
disk, 8 GB/batch) — never a client upload; movies are gigabytes.

## Index (migration 0008)

`catalog_movies` — one row per file (uuid PK, `rel_path` unique), with parsed
metadata (kind movie|episode, title, year, series, season, episode, overview)
and probed facts (duration, container, vcodec, width/height). Audio and
subtitle tracks are stored as a **JSON `streams` blob**, not normalized rows:
they're always read together with the movie and never queried into. FTS5 over
`title + series`, same trigger pattern as music.

**Scan** (admin-triggered, like the music catalog — never per-listing):
incremental `ffprobe` behind a `Prober` interface (so tests need no ffmpeg),
with a nil-prober guard. It parses the filename for structure — `Movie
(2019)`, `S01E03` / `1x05`, series name from the parent folder — discovers
sidecar subtitles next to the file, and (size, mtime) drives change detection.
Admin metadata edits win and survive rescans (only file facts refresh), keyed
by the stable UUID.

`watches` — the movie twin of music's `listens`, but **stateful**: the LATEST
`(position_ms, duration_ms)` per `(user, movie)` is the resume point. Movies
are long and cross-device resume is the whole point, so — unlike music, where
positions stay client-side — the server owns them.

## Endpoints

All under `movies:read` except scan/edit (`movies:write`). Streams sit OUTSIDE
the auth middleware (signed URL, see below).

| Endpoint | Purpose |
|---|---|
| `GET /v1/movies?q=` | list / FTS search (signed `stream_url` attached) |
| `GET /v1/movies/continue` | Continue Watching shelf (server resume, >95% drops off) |
| `GET /v1/movies/{id}` | detail + this user's `resume_ms` |
| `GET /v1/movies/{id}/stream` | the video (signed URL or bearer) |
| `GET /v1/movies/{id}/art` | poster, ETag'd |
| `GET /v1/movies/{id}/subs/{track}.vtt` | one subtitle track as WebVTT |
| `POST /v1/movies/{id}/watches` | report `{position_ms, duration_ms}` (clamped) |
| `PATCH /v1/movies/{id}` | admin metadata edit `[movies:write]` |
| `POST /v1/movies/scan` | index the drop directory `[movies:write]` |

## Streaming — the interesting part

The client reports its decode capability; `planPlayback` (shared, in
`media_codec.dart`) picks **direct-play vs transcode**. Today Phase A only
serves codecs the client can already decode, with one twist for multi-track:

- **Default audio, no seek** → `http.ServeFile` of the original bytes: full
  HTTP Range, perfect client-side seeking, zero server work.
- **Non-default audio track** (`?audio=N`) → **zero-CPU remux**: ffmpeg
  `-c copy` rewrites the container to fragmented MP4 with the chosen audio
  track mapped in. No re-encode — it's a container rewrite, ~free. This is how
  "play the English dub" works. A remuxed pipe can't serve Range, so seeking is
  done by **re-requesting with `?start=SEC`** (ffmpeg fast-seeks before the
  copy).
- **Subtitles** — embedded text tracks (`e<N>`) and sidecars (`x<N>`) are
  converted to **WebVTT** on demand (`ffmpeg -f webvtt`) and fed to the
  player's caption overlay. Image subs (PGS/VOBSUB) are hidden — they'd need
  OCR.

**ffmpeg lifecycle:** every ffmpeg call is `exec.CommandContext(r.Context())`,
so the subprocess is killed the instant the client disconnects — no orphaned
transcodes pinning CPU (the classic media-server footgun, avoided).

### Signed stream URLs (+ the fallthrough)

Listings carry a signed, bearer-free `stream_url` (HMAC over `stream:movie:<id>`
+ expiry, 24h TTL) — same mechanism as music, so playback outlives the 15-min
access token. The stream handler accepts a **valid signature OR a bearer with
`movies:read`**, and a stale/expired signature **falls through to the bearer
the client still attaches** — 401 only when neither holds. This matters because
the client snapshot-caches listings: without the fallthrough, a movie played
from a >24h cached listing 401'd silently. (This was a real bug, fixed in
review; there's a regression test.)

### Watch reporting

The player posts progress every 20s and on exit. The server **clamps**
`position_ms` to `[0, duration_ms]` so a buggy/hostile client can't poison
Continue Watching with negative or past-the-end positions.

## Client

- **Movies tab** — search, a Continue Watching shelf (resume progress bars),
  then a responsive poster grid (`SliverGridDelegateWithMaxCrossAxisExtent`,
  3-cols-on-phone → fills a desktop window). Posters flow through the content
  cache with a film-glyph placeholder; snapshot-first so the grid paints on
  cold start.
- **Detail** — responsive (poster beside metadata wide, stacked on phone);
  title/year/runtime/resolution, a track summary, overview, Play / Resume-from
  / Start-over.
- **Player** — landscape-locked immersive fullscreen on the central
  `PlaybackController` (so native PiP attaches later with no rework). Audio-track
  picker re-opens the stream through the remux at the current position;
  subtitle picker fetches WebVTT and overlays it. The client always attaches
  the bearer header even when using the signed URL, which is what makes the
  server fallthrough work.
- Service is manifest-gated (`movies:read`), grouped under Media, registered
  after the core dock services so it never bumps the dock.

## Admin (the panel)

Mirrors the music catalog manager: list (poster, title with SxxExx pill,
series, year, a "2 audio · 1 sub" tracks column), an edit page (metadata + a
read-only probed-media panel + poster override), browser upload + Scan, and a
typed-confirmation delete that trashes the file to `.trash/` (never hard-
deletes; the scan skips dot-dirs). Every mutation audits
(`movie.edit/delete/art`, `movies.scan/upload`) into the Activity feed.

## Phase B — real transcode (designed, not built)

Phase A only plays codecs the client already decodes. The remaining ~10% —
HEVC-in-MKV, VP9, AV1, AC3/DTS audio on iOS AVPlayer — needs a real transcode
to H.264/AAC, ideally segmented as **HLS** for smooth seeking + bitrate
adaptation. That work is CPU-heavy and bursty, so it belongs in its **own
container** (the transcoder) that vaultd delegates to over the shared library
volume, hardware-accelerated where the host allows. `planPlayback` already
returns `NeedsTranscode('hls-h264-aac-720p')` for those files; wiring it to an
HLS `.m3u8` from the transcoder is the Phase B build. This is Vault's first
real service split — and the reason it's worth splitting: transcode is the one
workload with a fundamentally different resource profile from the API.
