# vaultd

The Vault gateway (Go). Implements the client's `VaultClient` contract; see
`docs/backend/DESIGN.md` (v2.2) and `docs/backend/ROADMAP.md`.

## Layout

```
cmd/vaultd/            entrypoint
internal/config/       env-driven config
internal/store/        SQLite: ReadStore/WriteStore split, embedded migrations
internal/httpapi/      chi router, request-id + slog middleware, handlers
```

## Local dev

```bash
cd server/vaultd
go test ./...
VAULT_DATA_ROOT=$(mktemp -d) VAULTD_ADDR=127.0.0.1:18080 go run ./cmd/vaultd
curl -s 127.0.0.1:18080/healthz
```

## Config (env)

| var                    | default          | notes                              |
|------------------------|------------------|------------------------------------|
| `VAULTD_ADDR`          | `:8080`          | listen addr (Caddy proxies to it)  |
| `VAULT_DATA_ROOT`      | `/srv/vault`     | data + system root                 |
| `VAULTD_OIDC_ISSUER`   | —                | Pocket ID issuer (M2 auth)         |
| `VAULTD_OIDC_CLIENT_ID`| —                | vaultd's client id in Pocket ID    |
| `VAULTD_TOKEN_SECRET`  | —                | signs device access tokens         |

## Store design

Two handles by type: `store.Read()` (pooled reads) and `store.Write()` (a
single serialized write connection). Writers use `WriteStore.Tx`. This split
is what keeps SQLite from ever returning "database is locked" under
concurrent syncs — see the package doc.

## Auth model

- Pocket ID authenticates (OIDC, passkeys); vaultd authorizes (grants DB).
- Devices hold OPAQUE tokens (stored hashed): 15-min access + rotating
  refresh with a 60s grace window; reuse older than grace revokes the device.
- Users are invited by email (`vaultdctl user add maya --email …`); the
  first Pocket ID login with that email binds the OIDC identity.
- First-ever admin: on boot with an empty users table, vaultd logs a
  one-time setup code for `POST /v1/setup`.
- Admins implicitly hold every service+action; members hold exactly their
  grants. `GET /v1/manifest` serves the client's CapabilityManifest shape.

## vaultdctl

Admin CLI against the same DB (in the container:
`docker compose exec vaultd vaultdctl …`):

```
vaultdctl user list | user add <name> --email <e> [--admin] | user disable <name>
vaultdctl grant <name> <service> <action,...> | grant-remove | grants <name>
vaultdctl device list [name] | device revoke <device-id>
```

## Jobs (M3)

`internal/jobs`: a unified scheduler (concurrency cap + per-user fairness)
running two Runners — `TorrentRunner` (qBittorrent Web API, category-per-
user, per-job poll) and `YtdlpRunner` (yt-dlp subprocess, process-group
kill, progress parse). Completed artifacts are moved into the owner's
`downloads/` via `library.MoveInto` (atomic ingest + EXDEV fallback). Live
updates stream over SSE (`GET /v1/jobs/watch`) from a coalescing hub with
heartbeats and a 30-min cap; crashed `running` jobs are reconciled at boot.
All endpoints gated on `torrent:{read,write}`.

Extra config (env): `VAULTD_QBIT_URL/USER/PASSWORD`, `VAULTD_YTDLP_BIN`,
`VAULTD_MAX_JOBS`. The Docker image bakes yt-dlp + ffmpeg (rebuild to
refresh yt-dlp).

## Status

M2 (auth/identity/manifest) + M3 (jobs: torrent + yt-dlp) built and
integration-tested (`go test ./...`). Next: deploy M3 to the stack (set
QBIT_PASSWORD, rebuild), then M4 (photo backup).
