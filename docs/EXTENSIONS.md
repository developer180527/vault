# Web extensions

A way to add a service to Vault without rebuilding the Flutter app: a small web
app, shipped as a signed bundle, rendered inside the native shell, talking to
native capabilities through a versioned bridge.

The goal is that adding a service is a server-side act. The admin registers a
bundle, grants it to someone, and that person's app grows a tab — on every
device, with no store review, no download, no rebuild.

---

## Why this fits Vault specifically

Four of the five things a system like this needs already exist:

| Requirement | Existing machinery |
|---|---|
| Server decides who sees a service | `/v1/manifest` → `CapabilityManifest` |
| Client learns a service appeared | `changes.Bump` → SSE → `topicRevProvider` |
| Per-user permission | `grants` table, `KnownServices` / `KnownActions` |
| Somewhere to surface "new" | `Habits` (already records `recordServiceOpen`) |
| **Services defined at runtime** | ❌ **missing — `serviceRegistryProvider` is a const list** |

`permittedServicesProvider` already computes `registry × manifest`. Once the
registry can contain entries that came from the manifest, the entire
discovery flow — new service appears, tab shows up, dot on You — falls out of
code that is already written and already tested.

The single blocking change is `main.dart:60`:

```dart
serviceRegistryProvider.overrideWithValue(vaultServices),  // const list
```

This must become a composing provider: built-ins ∪ extensions-from-manifest.

---

## Two decisions that shape everything

### 1. Ship bundles, don't load URLs

The obvious implementation — point a WebView at `https://server/ext/foo` and
let a service worker cache it — is the wrong one here.

* Service workers in `WKWebView` are unreliable and unavailable for custom
  schemes, so iOS offline would silently not work.
* A remote URL has no integrity check. Vault is Tailscale-only, but "the
  server is trusted" is not the same as "this is the bundle I approved".
* The origin is the security principal for grants. A remote origin drifts
  (ports, hostnames, Tailscale MagicDNS vs IP); a local one does not.
* Rollback and version pinning are impossible if the server can change what
  is served under a URL at any moment.

Instead: vaultd stores a **versioned tarball with a SHA-256**. The client
downloads it, verifies the digest, unpacks it to disk, and serves it from a
**local origin** (`vaultext://<id>/`) via `flutter_inappwebview`'s custom
scheme handler.

That yields offline-by-construction (it is a local directory), integrity,
atomic version swaps, painless rollback, and a stable origin to key grants on.
Offline is not a feature bolted on — it is what a bundle *is*.

Revalidation reuses the shape `ContentCache` already uses for images:
serve from disk immediately, check for a newer version in the background,
swap on next launch. Never block the UI on the network.

### 2. The bridge is a wire protocol, not a Dart API

For an already-installed extension to survive an app update, the contract must
be data, not code. Every call is a JSON envelope over a single message channel:

```jsonc
// extension → native
{ "v": 1, "id": "7", "method": "haptics.impact", "params": { "style": "light" } }
// native → extension
{ "id": "7", "ok": true, "result": {} }
{ "id": "7", "ok": false, "error": { "code": "not_granted", "message": "…" } }
```

Rules that make it safe to change the implementation underneath:

* **Additive only.** A method is never removed, renamed, or repurposed. New
  behaviour is a new method or a new *optional* param. Old params keep their
  old meaning forever.
* **Feature detection, not version detection.** The handshake `bridge.hello`
  returns `{ bridgeVersion, methods: [...] }`. Extensions branch on whether a
  method exists, never on a version number. A three-year-old extension running
  against a new bridge sees a superset and keeps working.
* **Unknown method is a structured error**, never a crash and never a hang.
  An extension built against a newer bridge degrades on an older client
  instead of white-screening.
* **No token ever reaches JS.** Extensions do not get bearer tokens. Network
  access goes through `net.fetch`, which the *native* side authenticates and
  restricts to that extension's own server namespace.

**The honest caveat:** a flat, stable signature does not prevent *semantic*
drift. `storage.get` can keep its shape forever and still break callers if
what it returns changes. Signatures are checked by the compiler; semantics are
not. So the plan includes a conformance suite (Phase 5) — fixture extensions,
committed once, replayed against the bridge in CI forever. That suite is the
actual guarantee; the protocol rules are just what make the guarantee cheap.

---

## Bridge v1 surface

Deliberately small. Every method is grant-checked against the calling origin's
extension id on every call — never once at load.

| Method | Grant | Notes |
|---|---|---|
| `bridge.hello` | — | Handshake; returns version + method list |
| `haptics.impact` | — | Harmless, no data. The end-to-end proof. |
| `ui.toast` | — | Native snackbar |
| `storage.get/set/remove` | — | **Per-extension namespace.** Never the app keychain, never `vault_session_v1`. |
| `net.fetch` | `read`/`write` | Proxied natively; restricted to `/v1/ext/<id>/api/*` |
| `identity.whoami` | — | Display name + stable opaque id. An **attestation, not a credential**. |

`net.fetch` is the one with teeth — it is how an extension reaches its own
server-side half. Native attaches auth, and the path allowlist is derived from
the extension id, so extension A cannot call extension B's API or any core
Vault endpoint.

---

## Phases

### Phase 0 — Freeze the contract (no code)
Write the wire protocol, the v1 method table, and the additive-only rule into
this document before implementing. This is the part that is expensive to
change later.

### Phase 1 — Server: registry + bundle storage
* Migration `0013_extensions.sql` — `extensions(id, name, icon, category,
  version, bundle_sha256, size, required_actions, enabled, created_at)`.
* `internal/extensions` — store + bundle validation: tar.gz only, size cap,
  **reject path traversal and absolute paths**, must contain `index.html`,
  digest computed server-side on upload.
* `KnownServices` becomes a function over context: built-ins ∪ enabled
  extension ids, so the existing grant editor can grant them with no changes
  to its UI.
* `manifest.go` emits extension entries with
  `config: { kind: "webext", version, sha256 }`.
* `changes.Bump("services")` on register / update / enable / disable.
* `GET /v1/ext/catalog`, `GET /v1/ext/{id}/bundle`.
* adminweb page to upload and enable a bundle.

*Verify:* `go test ./...`, traversal fixtures rejected, a member's manifest
contains the extension only when granted.

### Phase 2 — Client: bundle cache + local origin
* Add `flutter_inappwebview`.
* `lib/core/ext/bundle_store.dart` — download → verify SHA-256 → unpack to
  `<support>/ext/<id>/<version>/` → atomic swap → retain one previous version
  for rollback.
* Serve from `vaultext://<id>/` via the custom scheme handler.
* Stale-while-revalidate against the manifest's version + digest.

*Verify:* airplane mode → extension still opens. Corrupt the tarball → refuses
to install, keeps the old version, logs loudly.

### Phase 3 — The bridge
* `lib/core/ext/bridge.dart` — one JS handler, envelope parse, method table,
  origin → extension id resolution, grant check per call, structured errors.
* Inject a strict CSP; block all external navigation and network from the
  WebView (everything goes through `net.fetch`).

*Verify:* unit tests for envelope handling, unknown methods, and a
grant-denied call. An extension with no `read` grant must be refused
`net.fetch` — this is the test that matters.

### Phase 4 — Dynamic registry + the dot
* `serviceRegistryProvider` from `overrideWithValue` to a composing provider.
  `permittedServicesProvider` is **untouched**.
* `ServiceDefinition.webext()` factory whose `builder` returns the WebView.
* `Habits` gains `seenServices`; `newServicesProvider = permitted − seen`.
* Dot on the You circle, cleared by the existing `recordServiceOpen`.

*Verify:* register an extension server-side against a running app → tab and
dot appear with no restart, driven purely by the `services` bump.

### Phase 5 — Conformance + hardening
* Commit fixture extensions exercising every v1 method; replay them against
  the bridge in CI. This is what makes "we can change the implementation"
  true rather than aspirational.
* Digest re-verified on every launch, not just on install.

---

## Scope boundaries

**First-party only, for now.** The moment one member can author an extension
that another member runs, member A's HTML executes inside member B's session
with member B's grants. That is a confused-deputy escalation, and defending it
means a real sandbox with a real review process — a different and much larger
project. Until then, only the admin registers bundles.

**This is a platform, not a feature.** The bridge, the versioning discipline,
and the conformance suite are permanent surface area. Worth entering
deliberately.

---

## Suggested first slice

Phases 0–4 narrowed to a single vertical: repurpose the unused `chat` service
id into a manifest-defined WebView with exactly **one** verb (`haptics.impact`)
plus the new-service dot.

That proves the two genuinely hard things together — a service arriving without
a rebuild, and web JS reaching native — while staying small enough to discard
if the ergonomics disappoint.
