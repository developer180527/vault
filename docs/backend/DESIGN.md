# Vault Backend Design

Status: v2.1 design, July 15 2026 — survived two adversarial review
rounds (see "Review decisions" at the bottom); ready to build against.
Next step: Phase 0 (Tailscale on the server), then the vaultd skeleton. The client's `VaultClient` interface
(`lib/core/client/vault_client.dart`) is the API contract this server
implements — keep them in lockstep.

## Principles

1. **Tailnet-only.** Zero public ports. Every byte travels inside Tailscale
   (WireGuard). A device that isn't enrolled in the tailnet cannot send a
   single packet to any service.
2. **One gateway.** The Flutter client talks to exactly one origin: `vaultd`
   (Go). Third-party services (qBittorrent, Pocket ID) are implementation
   details behind it — never exposed to clients directly, except admin UIs
   reachable only by admin devices via Tailscale ACLs.
3. **Fail closed.** No manifest → no services (the client already behaves
   this way). Unknown user → 401. Missing grant → 403. Every handler goes
   through the same authn→authz chokepoint.
4. **Boring storage.** SQLite for state, plain directories for user data.
   Easy to back up, easy to inspect, impossible to mismanage at family scale.
5. **Everything reproducible.** One `docker-compose.yml` + one `.env` +
   this document = the whole server. Rebuild from scratch in minutes.

## Network layer (do this first)

On the Debian host (not in Docker):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --hostname vault-server
```

- `--ssh`: Tailscale SSH replaces key management; later disable sshd on the
  LAN interface entirely.
- In the admin console: enable **MagicDNS** and **HTTPS certificates**.
- Tag the node `tag:vault-server` and add ACLs (Access Controls tab):

```jsonc
{
  "tagOwners": { "tag:vault-server": ["autogroup:admin"] },
  "acls": [
    // Everyone in the tailnet may reach the API gateway.
    { "action": "accept", "src": ["autogroup:member"],
      "dst": ["tag:vault-server:443", "tag:vault-server:8443"] },
    // Only the admin's devices reach admin surfaces (qBittorrent UI,
    // Pocket ID admin, SSH).
    { "action": "accept", "src": ["autogroup:admin"],
      "dst": ["tag:vault-server:*"] }
  ],
  "ssh": [{ "action": "accept", "src": ["autogroup:admin"],
            "dst": ["tag:vault-server"], "users": ["venu", "root"] }]
}
```

- TLS: `tailscale serve` gives a real Let's Encrypt cert for
  `vault-server.<tailnet>.ts.net` — the client speaks normal HTTPS with no
  certificate hacks.

### Routing: Caddy behind tailscale serve, one port per audience

`tailscale serve` fronts **Caddy**, one HTTPS port per surface. Subpath
routing for the IdP is deliberately avoided: identity providers expect to
own their root (`/.well-known/openid-configuration`, absolute asset
paths), and subpath rewrites break them in ways that surface as mystery
404s.

```
tailscale serve --bg --https 443  http://127.0.0.1:8080   # vaultd API (members)
tailscale serve --bg --https 9443 http://127.0.0.1:8081   # Pocket ID at ROOT (members: login/OIDC)
tailscale serve --bg --https 8443 http://127.0.0.1:8082   # admin surface (qBittorrent UI, ops)
```

ACLs: members → 443 + 9443; admins → everything. Pocket ID's own admin
panel lives behind its admin passkey (and only tailnet devices can reach
the port at all). OIDC issuer URL: `https://vault-server.<tailnet>.ts.net:9443`.

Caddyfile sketch — keep routing dumb and explicit so the proxy and the
ACLs can be verified against each other at a glance:

```
:8080 { reverse_proxy vaultd:8080 }        # member API
:8081 { reverse_proxy pocket-id:80 }        # IdP, root path, untouched
:8082 {                                     # admin surface
  handle_path /qbit/* { reverse_proxy qbittorrent:8090 }
}
```

Every container still binds 127.0.0.1 only; Caddy is the only thing the
serve layer touches.

## Identity & authorization

Two separate concerns, deliberately in two places:

- **Authentication (who are you)** — Pocket ID (self-hosted OIDC provider,
  passkey-based: nothing to phish, no passwords to manage for family).
  Admin creates each user; there is no self-signup. This IS the
  "authenticated by admin" requirement.
- **Authorization (what may you do)** — vaultd's own SQLite database. The
  IdP never knows about services or grants; vaultd never stores credentials.

### Flow

1. Flutter client runs Authorization Code + PKCE against Pocket ID
   (`flutter_appauth`), gets an ID token (JWT).
2. Client calls `POST /v1/devices/register` with the token + device info.
3. vaultd validates the JWT against Pocket ID's JWKS, looks the subject up
   in its `users` table (must exist and be `active` — admin approval),
   creates a `devices` row, and returns a **device-bound refresh token** +
   short-lived access token (vaultd's own, ~15 min).
4. Every subsequent request carries the access token. Middleware resolves
   (user, device), loads grants, and stuffs them in the request context.
5. Revoking a device = deleting its row. Revoking a person = deactivating
   the user (and/or in Pocket ID).

Hardening details (from review):

- **Admin bootstrap:** first boot with an empty users table prints a
  one-time setup code to stdout; `POST /v1/setup {code, oidc_token}` links
  that identity as the admin. No magic "first user wins".
- **IdP portability:** identities are keyed `(issuer, subject)` — swapping
  or adding an IdP later is a data migration, not a redesign.
- **Refresh rotation with grace:** rotating a refresh token keeps the
  previous token valid for a short grace window (~60s) and returns the
  SAME successor if replayed within it. A double-refresh on a flaky
  connection must not strand the device in a re-login loop. Reuse of a
  token *older* than the grace window revokes the whole family (theft
  signal).
- **No ongoing IdP session sync:** Pocket ID is consulted at enrollment and
  re-auth only; vaultd device tokens are the sole runtime session. Grant
  revocation is vaultd-local and immediate.

### Fine-grained authorization

Matches the client's `CapabilityManifest` exactly:

```
users    (id, oidc_subject, username, display_name, role admin|member,
          status active|disabled, created_at)
devices  (id, user_id, name, platform, token_hash, last_seen, created_at)
grants   (user_id, service_id, actions)       -- actions: JSON array
          e.g. ('u1','torrent','["read","write"]')
jobs     (id, user_id, kind, source, title, state, progress, message,
          created_at, updated_at)
photos   (id, user_id, content_hash, original_name, size, taken_at,
          mime, rel_path, created_at)          -- backup index + dedupe
```

- `GET /v1/manifest` returns the caller's grants in the client's manifest
  shape (`capabilities`, `defaultPinned`, `deviceId`, `profileId`). Flipping
  `_useMockManifest = false` is the moment the whole app goes real.
- **Single authz chokepoint:** every route declares `(service, action)`;
  one middleware checks the grant. Handlers never do their own permission
  logic. A missing grant is a 403 with the same shape everywhere.
- Guests = a user with a minimal grant set. There is no anonymous access.

### Why not roll auth fully into vaultd?

Passwords, hashing, resets, MFA, session fixation — solved problems with
sharp edges. Pocket ID is one small container and gives passkeys. vaultd
keeps the part that's genuinely domain-specific: devices + grants.

## Storage layout

Linux convention (`/Users` is macOS-ism; same idea, right home):

```
/srv/vault/
  users/<username>/
    files/          # My Files namespace root
    photos/         # backup originals (content-addressed subdirs)
    music/
    downloads/      # torrent + yt-dlp output
  system/
    db/vault.db     # SQLite (WAL mode)
    config/
```

- Per-user everything: a service writes ONLY under the requesting user's
  library. The library root is derived server-side from the authenticated
  user — never from a client-supplied path.
- **SafeJoin (the one path function):** every client-supplied path goes
  through a single `SafeJoin(userRoot, rel) (string, error)` that decodes,
  cleans, resolves symlinks (`filepath.EvalSymlinks` on the final path),
  and verifies the result still has `userRoot` as a prefix. Fuzz it in CI
  with `%2e%2e%2f`, unicode dot lookalikes, symlink chains, and absolute
  paths. There is exactly one chance to get this right.
- **Trash, not delete:** deletes move into
  `users/<u>/.trash/<timestamp>/...` with a purge job after 30 days. ZFS
  rollback stays the disaster tool, not the undo button. (The client's
  `FileRepository.trash` contract already promises this.)
- **staging/**: qBittorrent and other third-party workers write into
  `/srv/vault/staging/...` (the ONLY subtree mounted into their
  containers); vaultd moves completed artifacts into the owner's library.
  A compromised worker container can see in-flight downloads, never
  anyone's library.
### Ownership & the staging→library handoff

- **One system user for the whole stack:** vaultd and every worker
  container (qBittorrent PUID/PGID, yt-dlp) run as the same `vault`
  uid:gid. Staging dirs are setgid with `UMASK=002`. This removes the
  entire cross-uid failure class (unreadable payloads, unlink EACCES at
  the completion step) instead of managing it.
- Library dirs stay `0700`, owned by that uid. Isolation between workers
  and libraries comes from **mounts** (workers only see `staging/`), not
  from uid juggling.
- **MoveFile utility:** completion moves try `os.Rename` first; on
  `EXDEV` (staging and the user library on different filesystems — which
  becomes the NORM once per-user ZFS datasets exist) fall back to
  streaming copy → fsync → verify length/hash → unlink source. Never
  assume rename works across the staging boundary.
- Later: one ZFS dataset per user → quotas + per-user snapshots for free
  (this is exactly when the EXDEV fallback starts being exercised).

## Services

### File identifiers (contract note)

The client's `FileRepository` speaks node **IDs**, and storage is
path-based with no files table — resolved without breaking either: the ID
is an **opaque handle** that v1 defines as base64url of the user-relative
path. The server decodes it, runs SafeJoin, serves the file. No schema,
client contract untouched, and when a real file index arrives later (sync
journal), IDs change *meaning* without changing API *shape*. Clients must
never parse IDs.

### vaultd (Go, the gateway — you build this)

Single modular monolith, one binary, one container:

```
cmd/vaultd/            main, config
internal/httpapi/      routes, middleware (authn, authz, logging)
internal/auth/         OIDC verify, device tokens
internal/grants/       manifest + grant store
internal/jobs/         job store, scheduler, SSE fanout
internal/jobs/torrent/ qBittorrent Web API adapter
internal/jobs/ytdlp/   yt-dlp subprocess worker
internal/backup/       photo backup (hash check, upload, index)
internal/files/        My Files namespace (v1: direct fs)
internal/store/        SQLite (modernc.org/sqlite or mattn), migrations
```

Stack: Go stdlib `net/http` + `chi` router, `golang-jwt` + JWKS fetch,
SQLite in WAL mode. No ORM needed. Structured logs (slog) to stdout →
`docker logs`.

**API surface (mirrors `VaultClient`):**

| Client seam            | HTTP                                        |
|------------------------|---------------------------------------------|
| `fetchManifest()`      | `GET  /v1/manifest`                          |
| `jobs.submit()`        | `POST /v1/jobs`   {kind, source, title?}     |
| `jobs.cancel/retry`    | `POST /v1/jobs/{id}/cancel` `/retry`         |
| `jobs.clearFinished()` | `POST /v1/jobs/clear-finished`               |
| `jobs.watch()`         | `GET  /v1/jobs/watch` (SSE stream)           |
| `files.*`              | `GET/POST/PATCH/DELETE /v1/files...`         |
| streaming              | `GET /v1/files/{id}/content` (Range support) |
| backup (new)           | `POST /v1/backup/check` (hashes) → missing;  |
|                        | `PUT  /v1/backup/{hash}` (body = file)       |
| auth                   | `POST /v1/devices/register`, `/v1/token`     |
| admin                  | `GET/POST /v1/admin/users`, `/grants`, `/devices` |

SSE (not WebSockets) for job progress: plain HTTP, trivial in Go, maps
directly onto the client's `Stream<List<VaultJob>>`.

### qBittorrent (quick win #1)

`linuxserver/qbittorrent` container. WebUI on `127.0.0.1:8090`, exposed to
admins only via the 8443 surface. vaultd talks to it over the compose
network:

- Submit: `POST /api/v2/torrents/add` with
  `savepath=/srv/vault/staging/torrents/<username>`, `category=<username>`.
  On completion vaultd moves the payload into the owner's
  `users/<u>/downloads/`.
- Progress: **one global poller** using `/api/v2/sync/maindata` (qBit's
  purpose-built incremental-diff endpoint, single request per interval
  regardless of user count) → diff → job store → SSE fanout. Never poll
  per-user; a synchronous per-user poll loop collapses as members grow.
- Category-per-username keeps multi-user attribution inside one
  qBittorrent.

### yt-dlp (quick win #2)

No third-party web app needed — vaultd's worker runs `yt-dlp` as a
subprocess (binary + ffmpeg baked into the vaultd image and refreshed
every image build — extractors rot weekly), writing to
`staging/ytdlp/<u>/` then moving into the user's `downloads/`, parsing
`--newline` progress output into job updates.

Worker rules (from review):

- **Global FIFO with per-user fairness:** concurrency cap (2), next slot
  goes round-robin across users with queued jobs. One member queueing 50
  videos cannot starve everyone else.
- **No orphans:** subprocesses start in their own process group
  (`Setpgid`); cancellation and vaultd shutdown kill the group. Output goes
  to a temp name, atomically renamed on success.
- **Crash reconciliation:** on startup, any job still marked `running` is
  requeued (or failed with "server restarted") — a panic can never freeze
  the queue.

### Job store + live updates

- SQLite: WAL, `busy_timeout=5000`, and **one write connection for the
  ENTIRE database** — jobs, photos, devices, grants, everything — with
  reads on a separate pool. Scoping the single-writer to just the jobs
  engine would re-import "database is locked" the first time a photo sync
  and a device refresh collide. In Go: a `*sql.DB` with
  `SetMaxOpenConns(1)` for writes, a second handle for reads.
- Progress ticks update an in-memory job snapshot and flush to disk
  periodically; only state *transitions* write synchronously.
- **SSE fanout with backpressure:** each subscriber owns a buffered
  channel holding only the LATEST snapshot (coalescing writes, dropping
  intermediates). A phone with a saturated buffer can never block the
  fanout loop — it just gets the freshest state when it drains. Snapshots
  are per-user filtered: you watch your jobs, admins may watch all.

### Photo backup (Go, the flagship)

Content-addressed and dumb on purpose:

1. Client hashes originals (SHA-256) → `POST /v1/backup/check` in
   **batches of ≤500 hashes** (a 10k-hash single payload over a mobile
   tailnet is a guaranteed timeout) → server returns which are missing
   (dedupe across re-installs and shared albums for free).
2. Client uploads each missing file. Photos: single streaming PUT. Large
   videos: **resumable offsets** — `HEAD /v1/backup/{hash}` returns bytes
   received, `PUT` with `Upload-Offset` appends; a dropped connection
   resumes instead of restarting a 4K file.
3. Server hashes WHILE streaming to disk (constant memory, no buffering)
   into `users/<u>/photos/ab/cd/<hash>`, verifies, then indexes.
4. **Server extracts EXIF itself** (`taken_at`, dimensions, mime). The
   client's values are hints only — a buggy client must not be able to
   poison the index.
5. Client marks the asset backed up in its local index.

Thumbnails/transcodes are derived data — generate lazily, store in a cache
dir, never back them up.

### Streaming (music/video playback)

`GET /v1/files/{id}/content` and media endpoints use Go's
`http.ServeContent` on a real file handle: native Range requests, seek
support, sendfile — the gateway never holds file bytes in memory. This is
what makes scrubbing a movie on the phone work.

## docker-compose sketch

```yaml
services:
  # Only caddy binds host ports; everything else is reachable solely over
  # the compose network, by service name.
  vaultd:
    build: ./vaultd
    volumes:
      - /srv/vault:/srv/vault
    env_file: .env
    depends_on: [pocket-id, qbittorrent]
    restart: unless-stopped

  pocket-id:
    image: ghcr.io/pocket-id/pocket-id
    volumes: [pocket-id-data:/app/data]
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent
    # SAME uid:gid as vaultd (the `vault` system user) + group-writable
    # output — see "Ownership & the staging→library handoff".
    environment: [PUID=990, PGID=990, UMASK=002, WEBUI_PORT=8090]
    volumes:
      - qbit-config:/config
      # Staging ONLY — worker containers never see user libraries.
      - /srv/vault/staging/torrents:/srv/vault/staging/torrents
    restart: unless-stopped

  caddy:
    image: caddy:2
    ports:
      - "127.0.0.1:8080:8080"   # member API surface
      - "127.0.0.1:8081:8081"   # Pocket ID (root)
      - "127.0.0.1:8082:8082"   # admin surface
    volumes: ["./Caddyfile:/etc/caddy/Caddyfile:ro"]
    restart: unless-stopped
```

Tailscale serve maps 443 → caddy:8080 (member API), 9443 → caddy:8081
(Pocket ID), 8443 → caddy:8082 (admin surface). Nothing listens on
LAN/WAN interfaces.

## Admin experience

- v1: admin endpoints + a tiny `vaultdctl` CLI (`vaultdctl user add venu
  --admin`, `vaultdctl grant venu torrent read,write`). Bootstrap: first
  run prints a one-time admin registration code.
- v2: an **Admin service in the Vault app itself** — a service tab gated by
  the manifest like everything else (only admins receive the grant). Users,
  devices, grants, storage stats — managed from your phone.

## Security checklist

- [ ] No public ports; verify with an external scan (`nmap` from a
      non-tailnet network).
- [ ] All containers bind 127.0.0.1; only Tailscale serve fronts them.
- [ ] Containers run non-root (PUID/PGID), minimal volume mounts.
- [ ] Secrets in `.env` (never committed); tokens stored hashed.
- [ ] Access tokens short-lived; refresh tokens device-bound + revocable.
- [ ] Every path join goes through the one sanitizer; fuzz it.
- [ ] `unattended-upgrades` on host; images pinned by digest, updated
      deliberately.
- [ ] SQLite: WAL mode; nightly `sqlite3 vault.db ".backup ..."` cron into
      a dated file (+ ZFS snapshots once the pool exists). Litestream is
      overkill at this scale.
- [ ] Rate-limit auth endpoints (even on a tailnet — defense in depth).
- [ ] Structured logs (slog) with a **request ID** per request, user id
      when authenticated, and job id on job events. `docker logs | grep
      <request-id>` must reconstruct any incident.
- [ ] **Integration tests gate each phase**: a docker-compose test target
      spins the stack and drives real HTTP against auth, manifest, jobs,
      and SafeJoin fuzzing. Phase N+1 does not merge while Phase N's suite
      is red.

## Growth paths (what "scalable" means here)

- **More members:** the global sync poller and fair FIFO make per-user
  cost sublinear; SQLite reads scale far past family size. Nothing is
  per-user-polled or per-user-threaded.
- **More bandwidth:** vaultd streams (sendfile, constant memory); the
  gateway is never the bottleneck below NIC speed.
- **More disks:** `/srv/vault` becomes a ZFS pool; adding vdevs or
  per-user datasets is invisible to the application (paths don't change).
- **RAM/SSD/CPU upgrades or full machine swap:** all state lives in
  `/srv/vault` + one compose file + `.env`. Restore = install Tailscale,
  mount data, `docker compose up`.
- **A second machine:** workers already talk to vaultd over the network.
  A transcode or download worker moves to another tailnet box by pointing
  it at the same API + a shared staging mount (NFS over tailnet or
  syncthing). The jobs table is the queue; vaultd stays the only public
  surface.

## Review decisions (v1 → v2)

Accepted from external review: Caddy + two-port admin/member split (fixes
the Pocket ID login paradox), admin bootstrap endpoint, (issuer,subject)
identity keys, refresh-rotation grace window, global /sync/maindata
poller, SSE buffered coalescing fanout, yt-dlp fairness + process groups +
startup reconciliation, staging-mount isolation for worker containers,
SQLite single-writer + busy_timeout + batched progress, batched backup
checks, server-side EXIF, resumable large uploads, SafeJoin spec + fuzzing
+ trash-on-delete, request-ID logging, per-phase integration tests,
nightly SQLite backup over Litestream.

Rejected: "dual session sync overhead" (there is no ongoing IdP sync —
token exchange at enrollment only); "streaming blows up gateway RAM"
(http.ServeContent streams; nothing buffers whole files).

Round 2 (v2.1): unified uid:gid across vaultd + workers with setgid
staging and UMASK=002 (removes the cross-uid handoff failure class);
MoveFile with EXDEV streaming-copy fallback (mandatory once per-user ZFS
datasets exist); Pocket ID moved from a /id subpath to its own HTTPS port
(9443) because IdPs expect to own their root — this also deleted the
/id/admin 403 special-casing; SQLite single-writer scoped to the WHOLE
database, not just jobs; explicit Caddyfile documented. Modified rather
than accepted: file IDs stay IDs (the client contract already speaks
them) but are defined as opaque base64url-encoded relative paths — no
file_entries table, boring storage preserved.

## Phased rollout

1. **Phase 0 (an evening):** Tailscale up + MagicDNS + ACLs + serve TLS.
2. **Phase 1 (quick win):** compose up qBittorrent; verify torrenting from
   the phone via its WebUI over the tailnet. Vault app not involved yet.
3. **Phase 2:** vaultd skeleton — health, OIDC verify, users/devices/grants
   schema, `/v1/manifest`. Client gets `HttpVaultClient` + login screen;
   flip `_useMockManifest`. **The app is now real.**
4. **Phase 3:** jobs API (qBittorrent adapter + yt-dlp worker) → the
   client's Torrent tab operates the real server. Downloads land in user
   libraries.
5. **Phase 4:** photo backup endpoints + client backup engine.
6. **Phase 5:** files service against `users/<u>/files`, admin service in
   the app, streaming endpoints (HTTP range), quotas/ZFS datasets.
```
