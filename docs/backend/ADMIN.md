# Vault Admin Console — Design

Status: design, July 2026. **Not built yet — this is the spec.** Supersedes
`vaultdctl` as the *everyday* admin tool; the CLI stays as the break-glass
fallback (§9). Read `DESIGN.md` first — this inherits every principle there
(tailnet-only, one gateway, fail closed, additive `/v1`).

## 0. Why

Today all administration is `vaultdctl` (direct DB access on the server box) +
curl against the catalog endpoints. That works but means SSH for every task:
adding a user, granting a service, loading music, editing a tag, checking disk.
The admin console folds all of it into one secure GUI so the server is
manageable from the admin's phone or laptop — without ever opening a shell.

Scope of "all of this": **users & access, services, the music catalog,
activity/audit, and system/hardware health.**

## 1. Where it lives (the big decision)

**Inside the existing Flutter client, as an admin-only surface — not a
separate web app.**

Rationale:
- Reuses the whole security stack we already built: Pocket ID passkeys, opaque
  device tokens, the tailnet wall, the `VaultClient` seam. A separate web app
  would mean a second auth system and a second attack surface — exactly what
  "one gateway" (DESIGN.md §2) forbids.
- Cross-platform for free: a comfortable multi-pane console on macOS/Windows/
  Linux desktop, a scaled-down version on the phone for quick tasks.
- The manifest already gates navigation fail-closed. Admin becomes one more
  capability that simply never appears for non-admins.

The console is a new feature module (`lib/features/admin/`) surfaced as an
`admin` service in the capability manifest. It renders only when the manifest
carries the `admin` capability — and every action behind it is re-checked
server-side (the client gate is UX, never the security boundary).

## 2. Authorization — scoped, server-authoritative

Today `role == admin` implicitly grants everything. We keep that as the
default but split admin power into **scopes**, so a future "catalog curator"
can manage music without touching accounts:

| Scope | Powers |
|---|---|
| `admin:users` | users, invites, grants, device sessions |
| `admin:catalog` | music ingest, metadata edits, deletes |
| `admin:system` | hardware/health, service toggles, config |
| `admin:audit` | read the audit log |

The current admin role = all four (no behavior change for you). Scopes live in
the same grants table (`service = "admin"`, `actions = [...]`). Every
`/v1/admin/*` handler checks its scope in-handler via the existing
`RequireGrant`/`hasGrant` chokepoint — **the client manifest is never
trusted**. Non-admins get a 403 and the module never renders.

## 3. Step-up auth ("sudo mode") — the core security control

Reading admin data uses a normal session. But **destructive or sensitive
mutations require a fresh passkey re-assertion** within the last few minutes.
This is what stops an unlocked, logged-in phone from nuking accounts.

Flow:
1. Admin taps a guarded action (delete user, revoke all devices, delete
   tracks, edit another user's grants, rotate a secret).
2. Client calls `POST /v1/admin/elevate`, which forces a fresh Pocket ID
   passkey/biometric assertion (WebAuthn re-auth, not the cached token).
3. On success the server stamps the device session `elevated_until = now+5m`.
4. Guarded-mutation middleware requires a live `elevated_until`; otherwise
   403 `elevation_required` and the client re-prompts.

Elevation is per-device, short-lived, and rate-limited. Ordinary reads and
low-risk writes (e.g. editing a music tag) can stay outside it — we tune the
guarded set per endpoint.

## 4. Audit log — security control *and* the "activity" feed

New append-only table `admin_audit`:

```
admin_audit(id, actor_user, actor_device, action, target_kind, target_id,
            summary, request_id, tailnet_addr, created_at)
```

Every admin mutation writes exactly one row (who, what, which target, from
which device/tailnet address, when). Never store secret values — summaries are
redacted. The console surfaces this as the **Activity** section; it doubles as
forensic history if a device is ever compromised. Append-only, same discipline
as the `listens` ML log: we record facts, never mutate them.

## 5. Blast-radius guards (anti-lockout)

Hard server-side invariants, independent of the UI:
- Can't disable/delete **your own** admin account.
- Can't revoke **your own current device** session.
- **Last-admin protection**: the system refuses to remove the final
  `admin:users` holder.
- Destructive ops require typed confirmation (e.g. type the username to delete)
  *and* elevation (§3).
- `elevate` is rate-limited to blunt brute-force / fatigue attacks.

## 6. Information architecture

Desktop: left rail of sections + detail pane. Mobile: a list of sections, each
a full page. Sections map 1:1 to scopes.

**A. Overview / Dashboard** *(admin:system + admin:audit)*
Health at a glance: online users, running jobs, free space per ZFS pool,
backup freshness (3-2-1 snapshot ages), container status, vaultd version/build,
and any alerts (disk low, backup stale, container unhealthy).

**B. Users & Access** *(admin:users)*
- User list: role, status, last seen, device count.
- Create user / invite by email (binds to Pocket ID at first login), enable/
  disable.
- **Grant matrix**: users × services × actions, editable inline — a GUI over
  the grants table. This is the thing you most want.
- Device sessions per user: name, platform, last seen; revoke one or all.
- Bootstrap/setup-code management (generate/expire the one-time admin code).

**C. Services** *(admin:system)*
Every service (media, files, music, torrent, downloads, chat, admin…): toggle
globally, set default grants for new users, see who has access. A GUI over the
manifest/grants system.

**D. Music Catalog** *(admin:catalog)* — the immediate driver
- Browse the catalog with cover thumbnails.
- **Add songs** two ways: upload from the admin's device (multipart →
  `catalog/music/`), or trigger a rescan of the server drop directory.
- **Edit metadata**: form for title/artist/album/genre/track/year — the
  `PATCH /v1/music/catalog/{id}` endpoint that already exists; edits survive
  rescans by design.
- Delete tracks (cascades out of playlists; the file is trashed, not hard-
  deleted).
- Later: listen analytics (top tracks, per-user history) off the `listens` log.

**E. Activity & Audit** *(admin:audit)*
The `admin_audit` feed + auth events (logins, refreshes, failures) + jobs
across *all* users + listen-event volume. Filter by user / action / time.

**F. System & Hardware** *(admin:system)*
- **Disk**: `zpool status`/`list`, per-dataset usage, 3-2-1 backup snapshot
  ages.
- **Compute**: CPU load, RAM, temperature, uptime.
- **Containers**: vaultd / caddy / pocket-id / qbittorrent health + restart
  counts.
- **vaultd**: version/build/commit; config read-only with secrets shown as
  set/unset only (rotate-not-reveal).

Getting host metrics into a containerized vaultd is the one real infra
question here — options in §8.

**G. Settings** *(admin:system)*
Editable safe settings; secrets are never rendered, only "set / unset" with a
rotate action.

## 7. Server surface (all additive under `/v1/admin`, each scope-checked)

```
POST   /v1/admin/elevate                      step-up (fresh passkey)
GET    /v1/admin/users                         list
POST   /v1/admin/users                         create / invite
PATCH  /v1/admin/users/{id}                    enable/disable, role
GET    /v1/admin/users/{id}/devices            sessions
DELETE /v1/admin/devices/{id}                  revoke  [guarded]
PUT    /v1/admin/users/{id}/grants             set grant matrix [guarded]
GET    /v1/admin/services                       registry + defaults
PATCH  /v1/admin/services/{id}                  toggle / default grants
POST   /v1/admin/catalog/upload                 multipart ingest [admin:catalog]
POST   /v1/admin/catalog/scan                   (aliases the music:write scan)
GET    /v1/admin/audit                          the audit feed
GET    /v1/admin/system                         metrics snapshot
GET    /v1/admin/system/health                  container/service detail
```

Catalog metadata edit/delete already exist under `/v1/music/*` with
`music:write`; the console reuses them (admin holds `music:write`) rather than
duplicating. `admin:catalog` gates only the new upload/ingest surface.

## 8. Host metrics — the infra tradeoff (decide at build time)

vaultd runs in a container; hardware lives on the host. Options, cheapest
first:
1. **Read-only mounts**: bind `/proc`, `/sys` (ro) into the vaultd container;
   parse for CPU/RAM/temp/uptime. ZFS via a tiny host-side helper (cron writes
   `zpool status` to a file vaultd reads) — no privilege escalation in the API
   process. **Recommended**: simplest, least privilege.
2. A dedicated metrics sidecar (node-exporter-style) vaultd scrapes.
3. vaultd shells out to `zpool`/`docker` directly — needs host socket access;
   biggest blast radius, avoid.

Whichever we pick, the metrics endpoint stays read-only and the collection
path never gains write authority over the host.

## 9. Relationship to `vaultdctl`

`vaultdctl` stays — as the **break-glass tool**. It talks straight to the
store on the server box, so it works even when the API, Pocket ID, or the
network is broken (e.g. recovering a locked-out admin, first-boot bootstrap).
The console is the everyday tool; the CLI is the recovery tool. They share the
same store layer, so neither drifts from the other.

## 10. Rollout (phased — additive, nothing to migrate)

- **Phase 1** *(covers your immediate need)*: `admin` capability + scopes;
  read-only Overview; Users & grant matrix; Catalog management (upload / scan /
  edit / delete).
- **Phase 2**: audit log + `admin_audit` table + Activity feed; step-up
  elevation for guarded actions.
- **Phase 3**: System & Hardware metrics (§8 option 1).
- **Phase 4**: service toggles, settings/secret-rotation, listen analytics.

Each phase is additive `/v1` + additive migrations; the manifest gate means
older clients simply don't see the console until they update.
```
