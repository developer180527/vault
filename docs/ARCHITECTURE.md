# Vault — System Architecture

**Status:** Proposal v1 (2026-07-12)
**Scope:** Personal cloud for a trusted circle (family + close friends), self-hosted on a single home server. Not a public SaaS — architecture is right-sized for ~5–20 users and tens of TB, while staying robust and extensible.

---

## 1. Guiding principles

1. **Modular monolith, not microservices.** One deployable backend binary with strict internal module boundaries. A home server doesn't need service meshes; it needs reliability, easy upgrades, and one thing to babysit. Modules can be split out later only if a real need appears (e.g., transcoding on a second machine).
2. **Metadata in a database, blobs on the filesystem.** Files stay as plain files on disk in a content-addressed store — recoverable with `ls` and `cp` even if Vault itself dies. The database is an index, never the only copy of truth.
3. **Clients are dumb about storage, smart about sync.** All platform apps speak one HTTP+WebSocket API. Offline-first local state with a deterministic sync protocol.
4. **Secure by default.** No port-forwarded plaintext. Everything rides TLS; remote access via VPN overlay or hardened reverse proxy. Every device is individually enrolled and revocable.
5. **Boring technology.** Choose tools with 10-year track records over trendy ones. This system must run unattended for years.

---

## 2. High-level topology

```
┌─────────────────────────────  Clients (Flutter)  ────────────────────────────┐
│  iOS · Android · macOS · Windows · Linux · Web                               │
│  shared Dart core: API client, sync engine, local cache (SQLite), player     │
└──────────────────────────────┬───────────────────────────────────────────────┘
                               │  HTTPS (REST + ranged GET)  ·  WebSocket (events)
                               │  via Tailscale/WireGuard, or reverse proxy for web
┌──────────────────────────────▼───────────────────────────────────────────────┐
│                        Home Server (Docker Compose)                          │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     vaultd  (Go modular monolith)                   │    │
│  │  gateway/  auth/  users/  devices/  files/  sync/  media/           │    │
│  │  share/  search/  jobs/  admin/                                     │    │
│  └───────┬───────────────┬──────────────────┬─────────────────────────┘    │
│          │               │                  │                               │
│   PostgreSQL       Blob store (disk)   Worker pool (same binary)            │
│   metadata,        content-addressed   thumbnails, transcode (ffmpeg),      │
│   jobs queue       chunks + files      hashing, indexing, EXIF              │
│                                                                              │
│   Caddy (TLS reverse proxy)  ·  restic/borg (offsite encrypted backup)      │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Backend

### 3.1 Language & shape

- **Go** for the server (`vaultd`): single static binary, excellent concurrency for streaming/chunked I/O, first-class HTTP, trivial cross-compilation, low memory. (Rust is viable but slower to iterate; Node/Python struggle with sustained media streaming on modest hardware.)
- **One process, internal modules** with enforced boundaries (each module exposes a Go interface; no reaching into another module's tables). Suggested layout:

```
server/
  cmd/vaultd/            # main: wires modules, starts HTTP + workers
  internal/
    gateway/             # HTTP routing, authn middleware, rate limiting, OpenAPI
    auth/                # login, tokens, device enrollment, session revocation
    users/               # accounts, roles (owner/adult/child/guest), quotas
    devices/             # registered devices, push tokens, last-seen, remote wipe
    files/               # namespace tree, versions, trash, metadata
    blob/                # content-addressed storage engine (see 3.3)
    sync/                # change journal, cursors, upload sessions, conflicts
    media/               # thumbnails, transcoding, HLS packaging, EXIF/ID3
    share/               # per-item/per-album grants, share links (circle-only)
    search/              # SQLite FTS / Postgres tsvector index over metadata
    jobs/                # durable background queue (Postgres-backed)
    events/              # WebSocket fan-out of change notifications
  migrations/
```

### 3.2 Data stores

- **PostgreSQL** — all metadata: users, devices, file tree, versions, shares, sync journal, job queue. One store to back up, transactional, battle-tested. (SQLite would work at this scale but Postgres removes the single-writer ceiling and makes concurrent workers painless.)
- **Blob store on plain disk** — see 3.3.
- **No Redis initially.** The job queue and pub/sub live in Postgres (`FOR UPDATE SKIP LOCKED` + `LISTEN/NOTIFY`). One fewer service to run; add Redis only if measured contention demands it.

### 3.3 Blob storage (the heart of the system)

Content-addressed, chunk-based:

- Files are split into **content-defined chunks (~1–4 MB, FastCDC)**, each hashed with **BLAKE3**. A file = ordered list of chunk hashes (manifest stored in Postgres).
- Chunks stored at `data/chunks/ab/cd/abcd…` (sharded by hash prefix). Identical chunks across files/versions/users stored once → free dedup, cheap versioning, resumable transfers.
- **Write path is crash-safe:** chunk → temp file → fsync → rename. Manifest commit in Postgres is the atomic "file exists" moment.
- **Versioning & trash** are metadata operations (new manifest, old one retained). Garbage collection of unreferenced chunks runs as a periodic job with a grace window.
- Original files for media can additionally be **materialized** (hard-linked assembly) where streaming needs a contiguous file — a cache, never the source of truth.

### 3.4 API

- **REST + JSON over HTTPS**, defined in an **OpenAPI spec** (single source of truth; Dart client code is generated from it — keeps six platforms honest).
- **Ranged `GET`** for all downloads/streaming (HTTP `Range` headers) — this is what video/audio seeking, resume, and partial sync ride on.
- **WebSocket `/events`** per device: server pushes change notifications (`journal cursor advanced`, `job finished`, `device revoked`). Clients never poll.
- Versioned under `/v1/`; additive evolution, no breaking changes within a major version.

### 3.5 Sync protocol

- Server keeps an append-only **change journal** (monotonic sequence per user namespace). Every mutation (create/modify/move/delete/permission change) appends an entry.
- Each device holds a **cursor**. Sync = "give me journal entries after cursor N" → apply → advance. Deterministic, resumable, works after weeks offline.
- **Uploads:** client creates an *upload session*, sends chunk hashes first; server replies with which chunks it's missing (dedup + resume for free); client uploads only those; session commit creates the manifest atomically.
- **Conflicts:** last-writer-wins is wrong for files. On concurrent edit, keep both: the losing write becomes `name (conflicted copy — DeviceX 2026-07-12)`. Deletions never destroy: everything goes through trash with retention.
- **Photo/video auto-backup** is just a client policy on top of upload sessions (camera-roll watcher → queue → chunked upload), not a separate server mechanism.

### 3.6 Media pipeline

- On upload commit, `media` enqueues jobs: EXIF/ID3 extraction, thumbnail ladder (256/1024 px), video poster frame, audio waveform (optional).
- **Streaming strategy: direct-play first.** Serve original bytes with Range support whenever the client can decode them (most modern files). **Transcode only on demand** via ffmpeg to HLS (segmented .m4s + playlist) when codec/bandwidth requires it, with a small LRU cache of transcoded output. A home server can't afford Plex-style eager transcoding of everything.
- Hardware acceleration (VAAPI/QSV/NVENC) toggled by server config.

### 3.7 AuthN / AuthZ

- **Accounts:** username + password (argon2id) with optional TOTP. This is a family server — no OAuth federation needed, but the `auth` module is an interface so OIDC could be added later.
- **Device enrollment:** first login on a new device mints a **device record + refresh token bound to that device**. Short-lived access tokens (15 min JWT or opaque), refresh rotation, per-device revocation ("log out my lost phone") and remote cache-wipe flag.
- **Roles:** `owner` (admin), `member`, `guest` (read-only shares). Per-namespace ACLs: each user has a private root; shared spaces/albums grant `read`/`write` to listed users. Permission checks live in one place (`share` module) and every file/media/sync handler goes through it.
- **Share links** are circle-only by default (require login); public unauthenticated links are explicitly out of scope for v1.

### 3.8 Remote access & network security

- **Primary: WireGuard/Tailscale overlay.** Native apps talk to the server over the tunnel — zero ports exposed to the internet, and the web/API surface is unreachable to strangers by construction.
- **Web client / no-VPN fallback:** Caddy reverse proxy with automatic TLS on one hardened port, fail2ban-style rate limiting, and auth enforced at the app layer. Optionally mTLS or Tailscale Funnel instead of raw port-forwarding.
- All tokens/cookies `Secure` + `HttpOnly`; CORS locked to known origins for the web client.

### 3.9 Jobs, observability, backup

- **Jobs:** Postgres-backed durable queue; workers are goroutine pools in the same binary; retries with backoff; dead-letter table visible in the admin UI.
- **Observability:** structured logs (slog → files + journald), Prometheus `/metrics`, health endpoint; optional Grafana in compose. Admin dashboard shows storage, job queue, device list, journal lag per device.
- **Backup (the server itself needs backup):** nightly `pg_dump` + **restic/borg** encrypted snapshots of the chunk store to an offsite target (second box, B2, whatever). Vault is only a "backup solution" for its users if the server is itself recoverable. Restore procedure documented and tested.

### 3.10 Deployment

- **Docker Compose**: `vaultd`, `postgres`, `caddy`, optional `grafana`. One `.env`, one volume for Postgres, one for the blob store. Upgrades = pull + restart; DB migrations run automatically on boot (with journaled versioning, e.g., golang-migrate).

---

## 4. Client architecture (Flutter)

### 4.1 Package structure — feature-first, layered core

```
lib/
  core/
    api/          # generated OpenAPI client + interceptors (auth refresh, retry)
    auth/         # token storage (flutter_secure_storage), session state
    db/           # drift (SQLite): cached metadata, sync cursor, upload queue
    sync/         # sync engine: journal apply, upload sessions, conflict UI hooks
    transfer/     # chunker (BLAKE3 via FFI), resumable up/download, throttling
    player/       # media_kit wrapper: direct-play vs HLS selection
    platform/     # per-OS glue: background tasks, camera roll, file pickers
  features/
    onboarding/   # server address, enrollment, VPN hint
    library/      # file browser, organization, trash, versions
    photos/       # timeline, albums, auto-backup settings
    music/        # library, queue, offline pins
    video/        # library, playback, resume positions
    shares/       # shared-with-me, grant management
    settings/     # devices, storage usage, admin (owner only)
  app.dart        # router (go_router), theming, adaptive scaffold
```

- **State management: Riverpod** (compile-safe, testable, no context plumbing).
- **Local DB: drift** (typed SQLite) mirrors server metadata — the UI reads *only* from the local DB; the sync engine reconciles it with the server. This one rule gives offline mode, instant UI, and a single data path.
- **Media playback: `media_kit`** (mpv-based, all 6 platforms) with ranged HTTP; falls back to HLS URL when the server says "transcode".
- **Background work** is the only genuinely platform-specific area: iOS `BGProcessingTask`, Android `WorkManager` foreground service for camera backup, desktop just runs. Isolated behind `core/platform/`.
- **Web client** shares everything except: no chunk hashing worker locally (upload whole-file), no offline DB (or OPFS-backed later), playback via HLS.

### 4.2 Adaptive UI

One codebase, adaptive layout: navigation rail + master-detail on desktop/tablet, bottom nav on phones. Platform conventions (Cupertino back gestures, macOS menu bar) via adaptive widgets — not separate UIs per platform.

---

## 5. Cross-cutting decisions

| Concern | Decision | Why |
|---|---|---|
| API contract | OpenAPI-generated clients | 6 platforms can't hand-maintain a client |
| Hashing | BLAKE3, content-defined chunks | dedup, resume, integrity, fast on mobile |
| IDs | ULIDs | sortable, no coordination |
| Time | server clock is authoritative; clients send monotonic hints | family devices have wrong clocks |
| Encryption at rest | filesystem-level (LUKS/FileVault on server) in v1; E2EE deferred | E2EE breaks server-side thumbnails/transcode/search — a deliberate v2 research item |
| Telemetry | none leaves the house | it's the point of the product |

## 6. Delivery roadmap

1. **M1 — Skeleton:** vaultd with auth, device enrollment, plain file upload/download (no chunking), Postgres schema, compose file; Flutter app: onboarding + file browser on macOS/Android.
2. **M2 — Real sync:** chunked/content-addressed storage, journal + cursor sync, resumable uploads, trash/versions, WebSocket events.
3. **M3 — Photos:** camera-roll auto-backup (iOS/Android background), thumbnail pipeline, timeline UI.
4. **M4 — Streaming:** ranged direct-play music/video, on-demand HLS transcode, resume positions, offline pins.
5. **M5 — Circle:** multi-user, shares/albums, roles, admin dashboard, per-device revocation.
6. **M6 — Hardening:** server backup/restore drills, GC, quotas, metrics/alerts, remote wipe.

Each milestone ships something usable end-to-end; sync (M2) is deliberately before media, because everything else stands on it.

## 7. Explicit non-goals (v1)

- Public/unauthenticated sharing links
- End-to-end encryption (see table above — revisit after M6)
- Federation/multi-server, horizontal scaling
- Third-party plugin marketplace (extensibility = new internal modules first)
