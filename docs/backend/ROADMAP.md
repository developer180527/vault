# Vault Backend Roadmap

Companion to [DESIGN.md](DESIGN.md) (v2.2). Each milestone has an **exit
criterion** — a demonstrable behavior plus green integration tests — and
the next milestone does not start until it holds. Client work happens
inside each milestone (the app is the test harness the family actually
uses).

## M0 — Network foundation (an evening)

Server: install Tailscale (`--ssh`), MagicDNS + HTTPS certs, `tag:vault-server`,
ACLs (members → 443/9443, admins → all), the three `tailscale serve` ports.

**Exit:** `nmap` from a non-tailnet network shows zero open ports;
`https://vault-server.<tailnet>.ts.net` answers (even with a 502) from a
member device; SSH works via Tailscale only.

## M1 — Compose skeleton + qBittorrent (a weekend)

Server: `vault` system user (uid 990), `/srv/vault` tree + staging with
setgid, `docker-compose.yml` (caddy, qbittorrent, pocket-id), `.env`
convention, repo `server/deploy/` holds compose + Caddyfile.

**Exit:** from the phone (member device): Pocket ID login page loads on
:9443; from an admin device: qBittorrent WebUI on :8443 downloads a
torrent into `staging/torrents/`; from a family member's device :8443 is
unreachable (connection refused by ACL, not 403).

## M0 — DONE (Jul 15 2026). M1 — DONE (Jul 16 2026): Tailscale + Caddy 3-port split + Pocket ID login + qBittorrent handoff into staging (vault:vault, setgid verified) all working.

## M2 — vaultd skeleton + identity (1–2 weeks)  ← IN PROGRESS
##   Server side DONE + DEPLOYED (Jul 16 2026): vaultd live behind Caddy at
##   https://vault-server.taild29644.ts.net/ (healthz OK, OIDC ready against
##   Pocket ID, store+migrations, device tokens, manifest, vaultdctl — all
##   tested). Remaining: client HttpVaultClient + passkey login (task below).

Server (`server/vaultd/`): Go module; store layer (ReadStore/WriteStore
types, migrations, global single-writer); OIDC verification against
Pocket ID JWKS; `(issuer,subject)` identities; one-time admin bootstrap;
device registration + token rotation with grace window; authn/authz
middleware with request-ID logging; `GET /v1/manifest` from grants;
`vaultdctl user|grant|device` CLI. Integration suite: compose-based,
drives real HTTP (bootstrap, register, refresh races, manifest fail-closed).

Client: `HttpVaultClient` (manifest only), server-URL + login flow
(flutter_appauth + PKCE), device registration, token storage
(flutter_secure_storage), You page shows real identity; mock remains the
fallback when no server is configured.

**Exit:** factory-reset app on the phone → enter server URL → passkey
login → tabs appear per THIS user's grants; revoking a grant via
`vaultdctl` changes the phone's tabs on next manifest refresh; the
refresh-race integration test passes 100 consecutive runs.

## M3 — Jobs pipeline (1–2 weeks)

Server: jobs store + SSE endpoint (coalescing fanout, heartbeats, 30-min
stream cap); yt-dlp worker (global FIFO, per-user fairness, process
groups, startup reconciliation, atomic ingest); qBittorrent adapter
(cookie session wrapper, global `/sync/maindata` poller, category-per-user,
MoveFile with EXDEV fallback). Integration tests include kill -9 mid-job
→ clean recovery, and a slow-consumer SSE test.

Client: jobs API in `HttpVaultClient` (submit/cancel/retry/clear + SSE
watch with reconnect); Torrent tab now drives the real server.

**Exit:** paste a magnet AND a YouTube URL on the phone → both progress
live → files land in `users/<u>/downloads/` owned correctly; `docker
restart vaultd` mid-download → jobs recover without zombies; two users'
jobs interleave fairly.

## M4 — Photo backup (2–3 weeks)

Server: `/v1/backup/check` (≤500/batch), resumable uploads (HEAD offset +
append), hash-while-streaming through atomic ingest, server-side EXIF,
photos index, quota/507. Client: backup engine — local hash index,
batched checks, upload queue as `JobKind.upload` through the same jobs
UI, backup status in Media.

**Exit:** fresh device backs up the camera roll over the tailnet
(survives app kill + airplane mode mid-upload); re-install then re-backup
transfers zero file bytes (hash-check only); pulling a photo's EXIF date
from the server index matches reality, not the client's claim.

## M5 — Files service + streaming (2 weeks)

Server: `nodes` table (rename-stable UUIDs), SafeJoin + fuzz corpus in
CI, list/create/rename/trash (30-day purge), upload via atomic ingest,
`GET /v1/files/{id}/content` with Range. Client: files feature switches
from mock to server; media/music can stream server files.

**Exit:** browse/rename/trash from the phone; rename a parent folder →
pinned children keep working (ID stability test); scrub a large video
over the tailnet smoothly; SafeJoin fuzzer runs clean in CI.

## M6 — Admin & operations (ongoing)

Admin service tab in the app (users, devices, grants, storage stats —
manifest-gated to admins); nightly SQLite `.backup` cron + restore drill;
ZFS pool migration (per-user datasets, quotas, sanoid snapshots);
monitoring ping (ntfy) for job failures and disk thresholds.

**Exit:** admin can onboard a new family member entirely from the phone:
create user in Pocket ID (:9443), grant services in the Admin tab, they
log in and see their tabs — no SSH involved.

## Sequencing notes

- M2 is the keystone: everything after it reuses its auth middleware,
  store types, and test harness. Do not rush it.
- Client work in M3–M5 can develop against `MockVaultClient` in parallel
  with server work — the seam was built for exactly this.
- After M3 the family already has real daily value (remote torrent +
  yt-dlp); M4 is the flagship; M5 completes the core promise.
