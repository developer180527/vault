# Vault File Browser — Design Proposal

**Status:** Design draft (2026-07-12) — decisions marked *(proposed)* pending sign-off.

## 1. What it is (and isn't)

Not a general-purpose local file manager. It's a **window into the user's remote namespace on the home server**, presenting — in one unified tree — items that are:

- **remote-only** (on the server, not downloaded here),
- **synced / available** (present both places, current),
- **transferring** (up- or downloading right now),
- **local-only** (created/added on this device, not yet uploaded),
- **shared** (granted to me by another circle member, or shared by me),

…each with the right status shown, and the right actions available. Closest mental model: OneDrive/Dropbox "files-on-demand," scoped to a private home server.

## 2. Core principle — the UI reads only the local mirror

The browser **never lists the server directly.** It reads a local database (drift) that **mirrors the remote tree**, kept fresh by the sync engine from the server's change journal. This is the same rule the whole app follows, and it's what makes browsing **instant and fully offline-capable**. Actions mutate the mirror *optimistically* and enqueue work; badges reflect pending/failed state.

```
server journal ──▶ sync engine ──▶ local DB (mirror) ──▶ controller ──▶ UI
                                        ▲                     │
                          jobs queue ───┘   optimistic writes ┘
```

## 3. Domain model — one node, two orthogonal axes

A single `FileNode`:

- **identity:** `id` (ULID), `parentId`, `name`, `path`
- **kind:** folder | file; for files `mimeType`, `size`, `mediaKind?`
- **syncStatus:** `remoteOnly | downloading | available | uploading | localOnly | failed`
- **pinned:** bool — user asked to keep it available offline
- **shareStatus:** `private | sharedByMe | sharedWithMe` (+ owner, granted permissions)
- **meta:** `modifiedAt`, `version`, `thumbnailRef`, `isConflicted`, `isTrashed`

The design keeps two axes people conflate **separate**:
- **Where the bytes are** — `syncStatus` + `pinned`
- **Who can see it** — `shareStatus`

They get separate badges and separate actions.

## 4. Places (scopes)

The browser has a few entry points, not one root:

1. **My Files** — personal remote root.
2. **Shared with me** — items other members granted me.
3. **Offline** — everything pinned, for guaranteed-local access.
4. **Recents** — recently opened/modified.
5. *(later)* **Device backups** — camera roll / watched folders mapped to a server folder.

Desktop: a "Places" column in a secondary sidebar. Mobile: a segmented/scrollable header.

## 5. Sync model *(KEY DECISION — proposed: files-on-demand)*

**Files-on-demand:** you see the whole remote tree (metadata is cheap); file **bytes** download when you open or pin an item. Best fit for a home server + limited phone storage. Alternatives: *full mirror* (download everything — impractical on phones) or *selective-sync folders* (mark folders to fully sync — more control, more UI). Recommendation: files-on-demand, with per-item **pin for offline** covering the "keep this local" need.

## 6. Status vocabulary (badges)

| Badge | Meaning |
|---|---|
| ☁ cloud outline | remote-only — tap to download |
| ⭮ progress ring | transferring (down/up) |
| ✓ solid check | available offline (pinned) |
| ✓ faint check | cached (opened recently, evictable) |
| 👤 person | shared (direction/owner distinguishes with-me vs by-me) |
| ⚠ warning | conflict or failed transfer |

## 7. Actions — every one capability-gated by the manifest

- **read:** browse, open/preview, download
- **write:** new folder, upload, rename, move, pin/unpin
- **delete:** → trash (retention; client never hard-deletes)
- **share:** grant/revoke to circle members

Controls are **hidden entirely** when the capability is absent (consistent with the manifest system; the server still re-checks every request).

**Opening a file (in-app preview).** "Open" routes by media kind (`file_open.dart`), rendering everything in-app — no round-trip through an external app:

| Kind | Viewer |
| --- | --- |
| image | `FileImageViewerPage` — PhotoView, pinch-zoom / double-tap, streamed with the bearer |
| video | `FileVideoViewerPage` — the central `PlaybackController` (one video session, resume-aware); direct-play only (files have no transcode endpoint) |
| audio | enqueued into the audio player as a one-item queue (the mini-player appears) |
| pdf / markdown / code / text | `DocumentViewerPage` — pdfrx for PDFs, rendered markdown, and a selectable line-numbered mono view (wrap + copy) for code/text; JSON is pretty-printed |
| anything else | a "use Download" hint — nothing can render it in-app |

Bytes come from `/v1/files/{id}/content` with the bearer (refreshed up front so a long read/watch survives the 15-min token). Files are bearer-only — no signed URLs — so the audio path streams through just_audio's header proxy (fine here; it's not the hot music path). **Download** (native destination picker, streamed to disk) remains the escape hatch for unpreviewable types and for keeping a local copy.

## 8. Offline & optimistic behavior

Browsing works offline from the mirror. Mutations apply optimistically to the local DB and enqueue jobs via the `BackgroundRunner` port; status badges show pending/failed. Conflicts follow the sync design (keep-both, never destroy).

## 9. Desktop vs mobile — one controller, two presentations

- **Shared:** `FileBrowserController` (current place, path stack, selection, sort) + a repository over the local DB. All logic here.
- **Desktop (more features):** 3-pane — Places │ list with columns (name, status, size, modified) or grid │ preview/detail pane. Context menus, drag-and-drop upload/move, multi-select, keyboard nav, breadcrumb.
- **Mobile:** single column; tap to descend, breadcrumb/back; long-press or overflow → action sheet; swipe to pin/share; FAB for new folder / upload.

## 10. v1 scope (decided 2026-07-12)

- **Sync model: files-on-demand.** Whole tree visible from metadata; bytes download on open/pin. Per-item pin covers "keep offline."
- **Place: My Files only.** The share model lives in `FileNode.shareStatus` from day one, but the "Shared with me" place and any grant/revoke UI are deferred.
- **Sharing: view-only, later.** No grant UI in v1; when shared items appear they are read/open only.

**In v1:** browse My Files from the mirror (mocked until the server exists) · folder navigation + breadcrumb · status badges · **new folder + upload** (via `FileSystemAccess`) · **pin for offline** · **delete → trash** · **open media** handoff.

**Deferred:** Shared-with-me place, share grant/revoke, move/drag, versions UI, device-backup mapping, selective-sync, bulk ops.

### Build increments
1. **Read-only browser** — `FileNode` model, a mock files-on-demand repository, `FileBrowserController`, and My Files browsing (desktop list + mobile list) with status badges, folders, and breadcrumb. *(this increment)*
2. **Mutations** — new folder, upload (FileSystemAccess), pin/unpin, delete→trash, all capability-gated + optimistic.
3. **Desktop power UI** — columns/grid toggle, preview pane, context menus, drag-drop, multi-select.
