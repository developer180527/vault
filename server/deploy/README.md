# Vault server deploy (M1)

Runbook for the compose stack on the Debian box. Prerequisite: M0 done
(Tailscale up, node tagged `tag:vault-server`, ACLs saved, MagicDNS +
HTTPS certs enabled).

## 1. Get the bundle onto the server

```bash
# from the Mac:
rsync -av server/deploy/ venu@vault-server:~/vault-deploy/
# (or clone the repo on the server and cd server/deploy)
```

## 2. Bootstrap the filesystem + vault user

```bash
ssh venu@vault-server
cd ~/vault-deploy
sudo bash bootstrap.sh
```

Creates the `vault` system user (990:990) and `/srv/vault` per DESIGN.md
(setgid staging, tight system dirs). Idempotent — safe to re-run.

## 3. Configure

```bash
cp .env.example .env
openssl rand -base64 32     # paste into POCKET_ID_ENCRYPTION_KEY
nano .env                   # set TS_HOSTNAME to your MagicDNS name
```

## 4. Start the stack

```bash
docker compose up -d
docker compose ps           # all three: running
curl -s http://127.0.0.1:8080/healthz    # "ok: caddy up, vaultd pending (M2)"
```

## 5. Wire tailscale serve (one-time, persists across reboots)

```bash
sudo tailscale serve --bg --https=443  http://127.0.0.1:8080
sudo tailscale serve --bg --https=9443 http://127.0.0.1:8081
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8082
tailscale serve status
```

## 6. First-run setup

**Pocket ID (admin account):** from an admin device open
`https://<TS_HOSTNAME>:9443/setup` and register your passkey. This is the
Vault admin identity.

**qBittorrent:** grab the temporary WebUI password:

```bash
docker compose logs qbittorrent | grep -i password
```

Open `https://<TS_HOSTNAME>:8443` (admin device), log in as `admin` +
that password, then in Settings:
- change the password (store it in `.env` later for vaultd, M3);
- Downloads → Default Save Path: `/srv/vault/staging/torrents`;
- leave "Bypass authentication for clients on localhost" OFF (the compose
  network is not localhost; vaultd authenticates properly in M3).

## 7. M1 exit criteria

- [ ] Member device (family phone, non-admin): `https://<TS_HOSTNAME>:9443`
      shows the Pocket ID login page.
- [ ] Member device: `https://<TS_HOSTNAME>:8443` does NOT connect
      (connection refused/timeout — blocked by ACL, not a 403).
- [ ] Admin device: qBittorrent WebUI on `:8443` works; add a torrent and
      the payload lands under `/srv/vault/staging/torrents/`, owned
      `vault:vault`, group-writable.
- [ ] `curl https://<TS_HOSTNAME>/healthz` from any tailnet device returns
      the caddy health line.

## Notes

- Only Caddy binds host ports, and only on 127.0.0.1 — the tailnet is the
  sole way in.
- If Pocket ID fails to boot complaining about the encryption key, check
  its current docs — some versions want `ENCRYPTION_KEY_FILE` (a mounted
  file) instead of the `ENCRYPTION_KEY` env var.
- Update discipline: `docker compose pull && docker compose up -d`,
  deliberately, not automatically.
