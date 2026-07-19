# Photo Backup

Camera-roll → server backup. Content-addressed (sha256), deduped server-side,
resumable, and now **runs in the background without the app open**.

## The pass (`backup_core.dart`)

`runBackupCore` is a headless, provider-free function — the single source of
truth both the foreground engine and the background isolate call:

1. **Reconcile** the local ledger against what the server actually holds
   (self-healing: an item the server lost becomes eligible again).
2. **Enumerate** the roll (newest first), skipping ledger hits.
3. Per 40-item batch: **hash** (streamed from disk, never whole-file in RAM) →
   ask the server which hashes are **missing** → **upload** exactly those
   (originals, streamed) → record in the ledger.

The **ledger** (`asset id → sha256`, scoped per server+device) is an
optimization: losing it costs re-hashing, never re-uploading. Uploads are
idempotent and hash-verified server-side, so a truncated run is always safe to
resume.

## Foreground (`backup_engine.dart`)

`BackupEngine` wraps the core for the Photos status UI: maps progress ticks to
`BackupState`, refreshes the server listing as batches land, and — while music
is playing — yields between uploads so the audio stream keeps its Wi-Fi
airtime. Kicked on app launch when connected + auto-backup is on.

## Background (`background_backup.dart`) — runs without the app open

Android **WorkManager** (periodic) and iOS **BGProcessingTask**, via the
`workmanager` plugin.

- The OS runs `backupCallbackDispatcher` in a **separate Flutter isolate** with
  no widget tree and none of the app's providers. It stands up its own
  `ProviderContainer`, resolves the persisted session from secure storage, and
  reads only session / http-client / media-library providers — never
  playback/UI (which would try to init an AudioPlayer headless).
- **Constraints**: Wi-Fi only (`NetworkType.unmetered`), battery-not-low,
  storage-not-low — a large roll won't burn cellular data or battery.
- **Time budget** (~4 min): stop starting uploads before the OS reclaims the
  isolate; the ledger resumes next window. iOS re-arms itself at the end of
  each run (its scheduled tasks are one-shot); the app also (re)arms on every
  launch via `backgroundBackupSchedulerProvider`, watched at the app root.
- Scheduling tracks the auto-backup preference: on → schedule, off → cancel.

## Platform setup (already wired)

- **iOS**: `Info.plist` → `BGTaskSchedulerPermittedIdentifiers`
  (`dev.vault.backup.processing`) + `UIBackgroundModes` (`fetch`, `processing`);
  `AppDelegate.swift` registers the task id with `BGTaskScheduler` at launch;
  deployment target bumped to **14.0** (workmanager_apple requirement).
- **Android**: `INTERNET` + `ACCESS_NETWORK_STATE` permissions (INTERNET is
  auto-added only to debug manifests). WorkManager self-registers.

## Testing on device

Background windows are **opportunistic** — the OS decides when, favoring
charging + Wi-Fi + idle, often overnight. It will NOT fire on a schedule you
can watch.

- **iOS**: to force a run, pause the app in Xcode's debugger and run in the LLDB
  console:
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.vault.backup.processing"]`
  Watch for the `bgbackup` log tag.
- **Android**: `adb shell cmd jobscheduler run -f dev.venug.vault <jobId>`, or
  just leave it plugged into Wi-Fi; WorkManager fires within its window.
- Either way: toggle auto-backup on, add a new photo, background/close the app,
  and confirm it appears on the server after the next window.

Server side is unchanged — `/v1/photos/check` + `/v1/photos` (photos:sync).
