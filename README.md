# Vault

A self-hosted personal cloud for a household: your photos, music, movies, and
files on your own hardware, reachable from your own devices — and **nothing
else**. There are no public ports. The server is reachable only over your
[Tailscale](https://tailscale.com) network, so "exposed to the internet" never
enters the threat model.

One Go server (`vaultd`) and one Flutter client (iOS, Android, macOS, Windows,
Linux).

> **Status:** built for and run by its author's household. It works, it's
> tested, and it's in daily use — but it is not a polished product, and setup
> assumes you're comfortable with Docker, DNS, and a terminal.

## What it does

| Service | |
|---|---|
| **Photos** | Camera-roll backup from phones, deduplicated by content hash, originals kept |
| **Music** | A shared household catalog plus per-user libraries — playlists, favourites, play history, native gapless playback |
| **Movies** | A shared film/show library with resume-across-devices and subtitles |
| **Files** | A per-user file namespace; browse, upload, move, and push a folder from any device |
| **Torrents / Downloads** | qBittorrent and yt-dlp driven from the app, landing in your library |
| **Administrative** | Resumable multi-gigabyte uploads and metadata/artwork curation, from the client app |

Every service is gated per user by a **capability manifest** the server issues:
the client renders only what you're granted, and the server independently
enforces it. A family member can have music and photos but not torrents, and
the app simply doesn't show what they can't use.

## Architecture in one paragraph

The client talks to the server through a single typed seam (`VaultClient`) —
never raw HTTP scattered through features. Identity is
[Pocket ID](https://github.com/pocket-id/pocket-id) (passkeys, OIDC); the app
runs a standard Authorization-Code + PKCE flow in the system browser and enrols
the device, which then holds rotating tokens. Media streams over signed,
bearer-free URLs, so playback outlives a token refresh. A change feed (SSE)
pushes `{topic: revision}` ticks so every connected device refreshes when the
library changes, instead of polling. Storage is ZFS datasets, with photos and
movies separated so backup policy can treat "irreplaceable" and "re-obtainable"
differently.

Deeper design notes live in [`docs/`](docs/) — start with
[ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Running your own

**You will need:** a Linux box (Debian/Ubuntu tested), Docker + Compose, and a
Tailscale account.

```bash
git clone <your-fork> vault && cd vault/server/deploy
sudo ./bootstrap.sh                 # creates the vault user + /srv/vault layout
cp .env.example .env                # then edit: hostname, keys, passwords
docker compose up -d
```

Then follow [`server/deploy/README.md`](server/deploy/README.md) for the two
steps that can't be scripted: registering an OIDC client inside Pocket ID's
admin UI to get a client id, and wiring `tailscale serve`. First launch prints
a one-time setup code — the first device to use it becomes the admin.

### Building the client

```bash
flutter pub get
tool/rebrand.sh --bundle-id com.yourname.vault   # see below
flutter run -d macos            # or ios / android / windows / linux
```

**`tool/rebrand.sh` is not optional for a fork.** The bundle id doubles as the
OAuth redirect scheme (`<bundle-id>://oauth`) and appears in five places across
four platforms; if any one of them drifts, login fails at the callback with an
error that never mentions bundle ids. The script changes them together. Pass
`--team ABCDE12345` to also set your Apple signing team.

**On iOS specifically:** Apple requires *your own* Apple ID and team, and
sideloaded builds from a free account expire after 7 days. That's Apple's
policy, not a gap in this project. macOS, Android, Windows, and Linux have no
such restriction.

## Development

```bash
flutter analyze && flutter test                      # client
cd server/vaultd && go vet ./... && go test ./...    # server
```

## License

[GNU AGPL-3.0](LICENSE). You can run it, fork it, and change it freely. If you
run a **modified** version as a network service for other people, you must
publish your changes — so that a self-hosted project stays self-hostable by
everyone.
