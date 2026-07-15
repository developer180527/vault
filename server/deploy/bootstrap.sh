#!/usr/bin/env bash
# Vault server bootstrap (M1) — idempotent. Creates the `vault` system user
# and the /srv/vault tree per docs/backend/DESIGN.md ("Storage layout" +
# "Ownership & the staging→library handoff"). Run as root:
#
#   sudo bash bootstrap.sh
set -euo pipefail

PREFERRED_ID=990
ROOT=/srv/vault

# --- vault system group (gid shared by vaultd + worker containers).
# Prefer 990, but fall back to an auto-assigned system gid when 990 is
# already taken by another group (Debian assigns system ids top-down, so
# collisions are normal).
if ! getent group vault >/dev/null; then
  if getent group "$PREFERRED_ID" >/dev/null; then
    groupadd --system vault
    echo "gid $PREFERRED_ID taken ($(getent group $PREFERRED_ID | cut -d: -f1)); auto-assigned instead"
  else
    groupadd --system --gid "$PREFERRED_ID" vault
  fi
fi
VAULT_GID=$(getent group vault | cut -d: -f3)

# --- vault system user, same fallback logic.
if ! id vault >/dev/null 2>&1; then
  if getent passwd "$PREFERRED_ID" >/dev/null; then
    useradd --system --gid "$VAULT_GID" \
      --home-dir "$ROOT" --no-create-home --shell /usr/sbin/nologin vault
    echo "uid $PREFERRED_ID taken; auto-assigned instead"
  else
    useradd --system --uid "$PREFERRED_ID" --gid "$VAULT_GID" \
      --home-dir "$ROOT" --no-create-home --shell /usr/sbin/nologin vault
  fi
fi
VAULT_UID=$(id -u vault)

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

echo
echo "OK: $ROOT ready — vault is ${VAULT_UID}:${VAULT_GID}"
echo ">>> Make sure .env has:  VAULT_UID=${VAULT_UID}  VAULT_GID=${VAULT_GID}"
ls -la "$ROOT" "$ROOT/staging"
