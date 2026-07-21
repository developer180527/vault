# Movies — Shared Video Catalog

Status: **Phase A + B shipped** (catalog + direct-play + audio/subtitle
switching via zero-CPU remux, plus on-the-fly H.264/AAC transcode for codecs
the device can't decode). This doc is written retroactively from the shipped
code; treat it as the spec of record.

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

The client reports its decode capability (`MediaSupport` from
`media_codec.dart`), then `movieStreamMode` (`features/movies/data/
movie_playback.dart`) picks one of **three** modes from the device's decoders +
the file's codecs/container. It extends the shared `planPlayback` with container
awareness — decodable codecs in a container the device can't open need a remux,
not a full transcode:

- **Direct play** — decodable video + audio in a native container (mp4/mov/m4v)
  → `http.ServeFile` of the original bytes: full HTTP Range, perfect client-side
  seeking, zero server work.
- **Remux** (`?remux=1`, or any `?audio=N`) → **zero-CPU** ffmpeg `-c copy`
  container rewrite to fragmented MP4. Two triggers: a decodable file in a
  non-native container (H.264/AAC in MKV → fMP4), or a **non-default audio
  track** ("play the English dub"). No re-encode — ~free.
- **Transcode** (`?transcode=1`) → a real **H.264/AAC re-encode** to fragmented
  MP4 (`libx264 -preset veryfast -crf 23 -pix_fmt yuv420p`, `aac 2ch 160k`), for
  codecs the device can't decode at all: HEVC/VP9/AV1 video, AC-3/DTS/… audio.
  CPU-heavy, so it's **gated by a semaphore** (`MaxConcurrentTranscodes`,
  default 2) — a full pool answers **503** and the client can retry. Cheap paths
  (remux, subtitles) are never gated.

Remux and transcode are progressive fMP4 pipes — no HTTP Range — so seeking is a
**re-request with `?start=SEC`** (ffmpeg fast-seeks before decode). Only direct
play seeks client-side. The client mirrors this: `movieStreamMode` decides the
mode, and non-direct modes are server-seeked from the resume offset.

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
  `PlaybackController` (so native PiP attaches later with no rework). On open it
  probes device support and calls `movieStreamMode` to pick direct/remux/
  transcode; the audio-track picker re-opens the stream (remux) at the current
  position; the subtitle picker fetches WebVTT and overlays it. The client
  always attaches the bearer header even when using the signed URL, which is
  what makes the server fallthrough work.
- Service is manifest-gated (`movies:read`), grouped under Media, registered
  after the core dock services so it never bumps the dock.

## Admin (the panel)

Mirrors the music catalog manager: list (poster, title with SxxExx pill,
series, year, a "2 audio · 1 sub" tracks column), an edit page (metadata + a
read-only probed-media panel + poster override), browser upload + Scan, and a
typed-confirmation delete that trashes the file to `.trash/` (never hard-
deletes; the scan skips dot-dirs). Every mutation audits
(`movie.edit/delete/art`, `movies.scan/upload`) into the Activity feed.

## Phase B — real transcode (shipped)

The remaining ~10% of files — HEVC-in-MKV, VP9, AV1, AC-3/DTS audio the device
can't decode — now play via an **on-the-fly H.264/AAC transcode** (`Transcode`
in `internal/movies/stream.go`), streamed as progressive fragmented MP4 through
the same `?start=SEC` seek model as remux. It reuses vaultd's existing ffmpeg
(already in the container) rather than splitting a service — right for family
scale. The only new operational surface is the concurrency cap
(`MaxConcurrentTranscodes`, default 2) so a couple of viewers can't peg every
core; a full pool returns 503 and the client retries.

**Chosen over HLS** deliberately: progressive fMP4 reuses the exact streaming
model remux already uses (one pipe, seek-by-re-request), so it was a small,
well-understood addition. Segmented **HLS** (smooth in-buffer seeking + bitrate
ladders) and **hardware encoders** (videotoolbox/vaapi/nvenc via a host tuning
knob) remain the natural next step if transcode load ever justifies a real
service split — the workload with a fundamentally different resource profile
from the API.
