#!/usr/bin/env bash
# Vault server bootstrap (M1) — idempotent. Creates the `vault` system user
# and the /srv/vault tree per docs/backend/DESIGN.md ("Storage layout" +
# "Ownership & the staging→library handoff"). Run as root:
#
#   sudo bash bootstrap.sh
set -euo pipefail

VAULT_UID=990
VAULT_GID=990
ROOT=/srv/vault

# --- vault system user/group (uid:gid shared by vaultd + worker containers)
if ! getent group vault >/dev/null; then
  groupadd --system --gid "$VAULT_GID" vault
  echo "created group vault ($VAULT_GID)"
fi
if ! id vault >/dev/null 2>&1; then
  useradd --system --uid "$VAULT_UID" --gid "$VAULT_GID" \
    --home-dir "$ROOT" --no-create-home --shell /usr/sbin/nologin vault
  echo "created user vault ($VAULT_UID)"
fi

# Let the invoking admin browse /srv/vault for debugging.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  usermod -aG vault "$SUDO_USER"
  echo "added $SUDO_USER to group vault (re-login to take effect)"
fi

# --- directory tree
# users/    per-user libraries; vaultd creates users/<name> (0700) itself.
# staging/  the ONLY subtree worker containers may mount. setgid so files
#           created by any member of group vault stay group-owned; UMASK=002
#           in the workers makes them group-writable.
# system/   vaultd state (SQLite, config). Tightest perms.
install -d -o vault -g vault -m 0750 "$ROOT"
install -d -o vault -g vault -m 0750 "$ROOT/users"
install -d -o vault -g vault -m 2770 "$ROOT/staging"
install -d -o vault -g vault -m 2770 "$ROOT/staging/torrents"
install -d -o vault -g vault -m 2770 "$ROOT/staging/ytdlp"
install -d -o vault -g vault -m 0750 "$ROOT/system"
install -d -o vault -g vault -m 0700 "$ROOT/system/db"
install -d -o vault -g vault -m 0750 "$ROOT/system/config"

echo "OK: $ROOT ready"
ls -la "$ROOT" "$ROOT/staging"
