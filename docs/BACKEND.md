# Vault Backend — API & Sync Contract (Go)

**Status:** Design draft (2026-07-12). Cross-references [ARCHITECTURE.md](ARCHITECTURE.md) for topology and the content-addressed chunk store; this doc specifies the **wire contract** the client (especially the file browser) uses, and the concrete Go layout.

---

## 1. The one rule that shapes everything

The client **never lists the server directly.** The file browser reads the **local mirror** (drift). Two channels keep that mirror correct and fetch bytes:

1. **Metadata** (the whole tree) arrives via the **change journal** — pulled, with a WebSocket nudge.
2. **File bytes** arrive via **ranged blob GETs**, on demand (files-on-demand).

So "how does the file system talk to the backend" has two distinct answers: a *sync channel* for structure, and a *transfer channel* for content. They're deliberately separate.

```
        ┌──────────── sync channel (metadata) ─────────────┐
server journal ──GET /v1/journal?since=N──▶ sync engine ──▶ drift mirror ──▶ FileBrowser UI
        └── WS /v1/events "journal head=M" nudges the pull ─┘
        ┌──────────── transfer channel (bytes) ────────────┐
chunk store ──GET /v1/blobs/{manifest} (Range)──▶ local cache ──▶ open / pin
```

---

## 2. Four flows the file browser drives

**A. First sync (empty mirror).** Client cursor = 0 → `GET /v1/journal?since=0&limit=500` → server returns node snapshots → client inserts into drift, advances cursor to the batch head → repeats until caught up. Tree now visible, every file `remoteOnly`.

**B. Open / pin a remote-only file.** User taps a `remoteOnly` node → client sets `downloading` → `GET /v1/blobs/{manifestId}` with `Range` → assembles + caches bytes → sets `available` (and `pinned` if the user pinned). Pin = "don't evict from cache."

**C. Create a folder (mutation, increment 2).** Client optimistically inserts a `localOnly` node → `POST /v1/nodes {parentId,name,kind:folder}` → server, in one transaction, inserts the node **and** appends a journal entry → returns the node → client reconciles (`available`). Other devices see it when they pull the new journal entry.

**D. Another device changed something.** Server pushes `WS {type:"journal", head:M}` → client pulls `since=<cursor>` → applies → mirror updates live. No polling.

---

## 3. Identity & authorization

- **Device enrollment:** first login on a device mints a **device-bound token** (short-lived access + rotating refresh). Every request carries the access token.
- **Authorization is server-side on every request.** The client hiding a tab/button is UX only; the server re-checks capability + device identity for each call. (Defense in depth — matches the client's capability model.)
- **`GET /v1/capabilities`** returns the exact `CapabilityManifest` the client already consumes: `{ deviceId, profileId, capabilities: {serviceId: {actions, config}}, defaultPinned }`.

---

## 4. Postgres data model (sync-critical tables)

```sql
-- one row per file/folder in a user's namespace
nodes(
  id            ulid primary key,
  namespace_id  ulid not null,          -- = owning profile's root namespace
  parent_id     ulid null references nodes(id),
  name          text not null,
  kind          smallint not null,      -- 0 folder, 1 file
  mime          text,
  size          bigint,
  media_kind    smallint,               -- none/image/video/audio/document
  manifest_id   ulid null,              -- chunk manifest for files
  version       int not null default 1,
  is_conflicted bool not null default false,
  modified_at   timestamptz not null,
  trashed_at    timestamptz null,       -- soft delete; GC after retention
  unique(parent_id, name) where trashed_at is null
)

-- append-only, monotonic per namespace: the sync spine
journal(
  seq          bigint generated always as identity,  -- global; per-namespace view via index
  namespace_id ulid not null,
  node_id      ulid not null,
  op           smallint not null,       -- create/update/move/delete/share
  snapshot     jsonb not null,          -- full node state (or tombstone) after the op
  created_at   timestamptz not null default now()
)
create index on journal(namespace_id, seq);

device_cursors(device_id ulid primary key, namespace_id ulid, last_seq bigint)
shares(node_id ulid, grantee_profile_id ulid, perms smallint, primary key(node_id, grantee_profile_id))
manifests(id ulid primary key, chunk_hashes text[], total_size bigint)  -- + chunks table per ARCHITECTURE.md
```

**Invariant:** every node mutation and its journal append happen in **one transaction**, so the journal can never disagree with node state, and a client replaying the journal is deterministic.

---

## 5. The sync protocol

- **Monotonic `seq` per namespace.** The journal is the source of truth for *ordering*.
- `GET /v1/journal?since=N&limit=500` → `{ entries: [{seq, op, snapshot}], head: M }`. Client applies each entry **idempotently** (upsert by node id / apply tombstone), then sets cursor = `M`.
- `WS /v1/events` frames: `{type:"journal", namespace, head}`, `{type:"job", id, status}`, `{type:"device_revoked"}`. The journal frame just tells the client to pull; the bytes still come over HTTP.
- **Resumable & offline:** a device gone for weeks just pulls from its stored cursor. No special catch-up path.

---

## 6. Transfer channel (files-on-demand)

- **Download / stream:** `GET /v1/blobs/{manifestId}` honoring `Range`. Server assembles the chunk sequence (or streams a materialized file from the cache). This is the same endpoint media streaming rides on.
- **Upload (write path, increment 2):** content-defined chunking + BLAKE3 **on the client**, then:
  1. `POST /v1/uploads` `{parentId, name, size, chunkHashes[]}` → server replies `{uploadId, missing:[hashes]}` (dedup: it only wants chunks it doesn't already have).
  2. `PUT /v1/uploads/{id}/chunks/{hash}` for each missing chunk.
  3. `POST /v1/uploads/{id}/commit` → server creates the manifest + node + journal entry in one transaction.
  Resumable (re-probe `missing`), dedup-ing (identical chunks stored once).

---

## 7. Endpoint summary

| Area | Endpoint | Notes |
|---|---|---|
| Auth | `POST /v1/auth/login`, `/devices`, `/refresh` | device-bound tokens |
| Capabilities | `GET /v1/capabilities` | the client's manifest |
| Sync | `GET /v1/journal?since=&limit=` | metadata catch-up |
| Events | `WS /v1/events` | push nudges (no bytes) |
| Nodes | `POST /v1/nodes`, `PATCH /v1/nodes/{id}`, `DELETE /v1/nodes/{id}` | create / rename·move / trash |
| Blobs | `GET /v1/blobs/{manifestId}` (Range) | download + stream |
| Uploads | `POST /v1/uploads`, `PUT …/chunks/{hash}`, `POST …/commit` | chunked, resumable, dedup |
| Media | `GET /v1/nodes/{id}/thumbnail`, `/stream` | thumbs + HLS/direct-play |
| Shares | `GET /v1/shares` (v1: read); grant/revoke later | |

All under `/v1`, JSON except blob bodies; additive evolution within the major version.

---

## 8. Go service layout

Single binary (`vaultd`), modular monolith (per ARCHITECTURE.md §3). Concretely:

```
cmd/vaultd/main.go            wires modules, starts HTTP + workers + WS
internal/
  gateway/    chi router, auth middleware, OpenAPI, rate limiting
  auth/       login, device enrollment, token rotation
  capability/ builds the manifest for (device, profile)
  files/      node tree: create/rename/move/trash, path queries
  sync/       journal append (tx-wrapped), cursor reads, GET /journal
  blob/       chunk store: probe/put/get, manifest assembly (BLAKE3)
  uploads/    upload sessions (probe → put → commit)
  media/      thumbnail + transcode jobs, streaming
  share/      grant checks (read path v1)
  events/     WS hub; fed by Postgres LISTEN/NOTIFY on journal insert
  jobs/       durable queue (Postgres SKIP LOCKED)
migrations/
```

- **DB access:** `pgx` + `sqlc` (typed queries). One `nodes`+`journal` transaction per mutation.
- **WS fan-out:** journal insert fires `NOTIFY journal_<namespace>`; the `events` hub `LISTEN`s and pushes `head` to connected devices. No Redis needed at home-server scale.
- **Auth middleware** resolves device+profile once per request; handlers call `share`/`capability` for per-action checks.

---

## 9. Conflicts & ordering

- Server assigns `seq`; that *is* the ordering. Metadata edits are **last-writer-wins per node** (the later `modified_at`/version wins the name/location).
- **Content** conflicts (two devices upload different bytes to the same path concurrently) never destroy: the loser becomes a new node `name (conflicted copy — Device X)`, flagged `is_conflicted`, surfaced by the client's ⚠ badge (already modeled in `FileNode`).
- **Delete** is soft (`trashed_at`); chunks are GC'd only after a retention window with no manifest referencing them.
```
