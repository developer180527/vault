# Vault Admin Console — Design

Status: design, July 2026 (rev 2 — web panel). **Not built yet — this is the
spec.** Supersedes `vaultdctl` as the *everyday* admin tool; the CLI stays as
the break-glass fallback (§9). Read `DESIGN.md` first — this inherits every
principle there (tailnet-only, one gateway, fail closed, additive `/v1`).

> **Rev 2 note:** §1 originally put the console inside the Flutter client.
> Decided against: admin is desktop-shaped, sit-at-a-desk work, and a
> tailnet-only web panel gives zero-install access from any browser with a
> *simpler* OIDC flow than the app. The security model is unchanged — same
> Pocket ID, same vaultd authz, same tailnet wall. See §1.

## 0. Why

Today all administration is `vaultdctl` (direct DB access on the server box) +
curl against the catalog endpoints. That works but means SSH for every task:
adding a user, granting a service, loading music, editing a tag, checking disk.
The admin console folds all of it into one secure GUI so the server is
manageable from the admin's phone or laptop — without ever opening a shell.

Scope of "all of this": **users & access, services, the music catalog,
activity/audit, and system/hardware health.**

## 1. Where it lives (the big decision)

**A tailnet-only web panel, served by vaultd, reachable only from admin
devices — NOT inside the Flutter client, NOT a public site.**

Why the web panel wins for admin specifically:
- **Admin is desktop-shaped.** Grant matrices, user tables, metadata forms,
  health dashboards — this is sit-at-a-desk work that wants a big screen and a
  keyboard, not a phone tab.
- **Zero install, any device.** Any browser on the tailnet reaches it; no app
  build to ship to the machine you happen to be at.
- **The OIDC flow is *simpler* than the app's.** The app does a custom
  URL-scheme AppAuth dance (`com.venug.vault://oauth`). A browser does the
  standard Authorization-Code + PKCE redirect that Pocket ID is built for —
  passkeys included.
- **The architecture already anticipates it.** DESIGN.md §2 allows "admin UIs
  reachable only by admin devices via Tailscale ACLs," and the ACL already
  splits `autogroup:member` (443) from `autogroup:admin` (all ports). Pocket
  ID (9443) and qBittorrent (8443) are already admin-only web UIs. The panel
  is one more.

**The security model does not change.** Same Pocket ID identity, same vaultd
authz (§2), same tailnet wall. It is NOT "a second auth system / second attack
surface" — that objection only holds if you build a separate login, which we
explicitly do not. Every `/v1/admin/*` call goes through the same
authn→authz chokepoint.

### Serving & stack

- **vaultd serves it**, static assets embedded via Go `embed` — nothing new to
  deploy, ships in the one binary. Bound to an **admin-only port** (e.g. 8444)
  and locked to `autogroup:admin` in the Tailscale ACL. No public exposure.
- **Server-rendered HTML + htmx**, no JS build step, no second codebase. Admin
  is forms/tables/dashboards — htmx's `hx-post`/`hx-get` swapping fragments is
  the whole interaction model, and it keeps the "boring, reproducible" ethos.

### Deploy topology (exact, matching the one-port-per-audience rule)

```
browser ── tailscale serve :8444 (ACL: autogroup:admin only)
             └→ caddy :8083 (localhost)
                  └→ vaultd admin listener :8081 (in-container; the member
                     API stays on :8080 — two listeners, one process, so the
                     member surface can NEVER route to an admin handler)
```

New wiring: one compose port (`127.0.0.1:8083:8083`), one Caddyfile site, one
`tailscale serve` command, one ACL line. The admin listener only starts when
`VAULTD_ADMIN_ADDR` + `VAULTD_ADMIN_EXTERNAL_URL` are set — undeployed means
off, fail closed.

**OIDC client:** reuse the EXISTING Pocket ID public client (PKCE) — the
admin just adds the web callback URL
(`https://<host>:8444/oauth/callback`) to its allowed redirect URIs. No
second client, no new secret; one less thing to rotate.

### The one genuinely new server piece: browser sessions

The app carries an opaque bearer token in secure storage. A browser wants an
**HttpOnly, Secure, SameSite=Strict cookie** session instead. So vaultd gains
a small cookie-session path:

- `/login` starts a server-side Authorization-Code + PKCE flow (state, nonce,
  verifier held in a short-lived HttpOnly cookie); the callback exchanges the
  code with Pocket ID, verifies the `id_token` (same JWKS discipline as the
  app path, plus the nonce), and maps identity → user via the same
  `(issuer, subject)` binding the app uses.
- Only `role == admin` + `status == active` gets a session; everyone else is
  a 403 at the door.
- The session token is random, stored **sha256-hashed** in a new
  `admin_sessions` table (same discipline as device tokens), 12-hour absolute
  expiry, revocable by row delete.
- **CSRF**: `SameSite=Strict` already stops cross-site cookie sends in every
  current browser; mutations additionally require a same-origin
  `Sec-Fetch-Site`/`Origin` check. No token machinery — one less state to
  desync, same protection. (Revisit only if a token-less browser matters,
  which on a personal tailnet it does not.)

## 2. Authorization — server-authoritative; scopes deferred

**Phase 0–1 gate: `role == admin`, checked at ONE middleware chokepoint** on
the admin listener. Rationale (a self-correction): the existing `hasGrant`
already short-circuits `role == admin` → allow-all, and only admins can reach
the panel at all — so per-scope grants that every possible visitor holds are
dead configuration. Adding them now is YAGNI.

The **scope split stays in the design** for the day a sub-admin role exists
(e.g. a "catalog curator" who manages music but not accounts):

| Scope (future) | Powers |
|---|---|
| `admin:users` | users, invites, grants, device sessions |
| `admin:catalog` | music ingest, metadata edits, deletes |
| `admin:system` | hardware/health, service toggles, config |
| `admin:audit` | read the audit log |

Because the check lives in one middleware, moving from "role == admin" to
"holds scope X" later is a one-function change — the same grants table
(`service = "admin"`) is ready for it. Either way the browser is never
trusted: every request re-resolves the session → user → role server-side.

## 3. Step-up auth ("sudo mode") — the core security control

Reading admin data uses a normal session. But **destructive or sensitive
mutations require a fresh passkey re-assertion** within the last few minutes.
This is what stops an unlocked, logged-in phone from nuking accounts.

Flow (corrected mechanism — vaultd cannot run raw WebAuthn; the passkeys live
in Pocket ID, so elevation is an OIDC **re-authentication**):
1. Admin clicks a guarded action (delete user, revoke all devices, delete
   tracks, edit another user's grants, rotate a secret).
2. The panel redirects through the OIDC flow again with `max_age=0` /
   `prompt=login`, which forces Pocket ID to demand a FRESH passkey assertion
   (the IdP session cookie is not enough).
3. The callback checks the new `id_token`'s `auth_time` is recent, confirms
   the same subject, and stamps the session `elevated_until = now+5m`.
4. Guarded-mutation middleware requires a live `elevated_until`; otherwise
   the action re-prompts.

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

- **Phase 0 — the shell** *(the plumbing everything else hangs off)*: the
  admin listener + deploy chain (8444→8083→:8081) + ACL entry; migration for
  `admin_sessions`; the browser OIDC flow (state/nonce/PKCE) + cookie session
  + same-origin mutation guard; a login gate landing on a real (small)
  Overview. **Zero JavaScript in Phase 0** — plain server-rendered pages and
  form posts; htmx is vendored in Phase 1 when inline table edits actually
  need it. Proves the whole auth/serve path end-to-end before any feature.
- **Phase 1** *(covers your immediate need)*: Users list + grant matrix;
  Catalog management (browse / scan / edit / delete — reusing the existing
  `music:write` endpoints).
- **Phase 2**: audit log + `admin_audit` table + Activity feed; step-up
  elevation (WebAuthn re-assert) for guarded actions.
- **Phase 3**: System & Hardware metrics (§8 option 1).
- **Phase 4**: service toggles, settings/secret-rotation, listen analytics.

Each phase is additive `/v1` + additive migrations. Nothing ships to the
Flutter client — the panel is entirely server-side.
```
