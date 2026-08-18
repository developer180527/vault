import 'package:flutter/material.dart';

import 'backup_engine.dart';

/// How a [BackupState] is described to the user.
///
/// Lives here, not in the widgets, for two reasons: the status appears in two
/// places (the Photos card and the media toolbar's cloud button) and they used
/// to drift, and because the wording is load-bearing enough to deserve tests.
///
/// The rule these encode: **never imply bytes are moving when they aren't.**
/// Most of a backup pass is hashing local files and asking the server what it
/// already holds. After a reinstall the on-disk ledger is gone, so that
/// verification covers the ENTIRE library while uploading nothing — and the
/// old copy called all of it "Backing up…", which read as a full re-upload.

/// True while a pass is doing work (any non-terminal phase).
bool backupIsRunning(BackupState s) =>
    s.phase == BackupPhase.scanning ||
    s.phase == BackupPhase.verifying ||
    s.phase == BackupPhase.uploading;

/// The headline. [BackupPhase.done] splits on whether anything was actually
/// sent, so a no-op pass says so rather than claiming credit for work.
String backupStatusTitle(BackupState s) => switch (s.phase) {
      BackupPhase.idle => 'Ready to back up',
      BackupPhase.scanning => 'Scanning camera roll…',
      BackupPhase.verifying => 'Checking what’s already backed up…',
      BackupPhase.uploading => 'Backing up…',
      BackupPhase.done =>
        s.uploaded == 0 ? 'Everything already backed up' : 'Backed up',
      BackupPhase.error => 'Backup incomplete',
    };

/// The line under the progress bar.
String backupProgressDetail(BackupState s) => switch (s.phase) {
      // "checked", not "backed up" — and say outright that nothing is queued,
      // because this is the phase that used to look like a re-upload.
      BackupPhase.verifying => '${s.done} of ${s.found} checked'
          '${s.uploaded == 0 ? ' — nothing to upload' : ''}',
      BackupPhase.uploading => s.current.isEmpty
          ? '${s.uploaded} uploaded · ${s.done} of ${s.found}'
          : '${s.done} of ${s.found} — ${s.current}',
      BackupPhase.done => s.uploaded == 0
          ? '${s.done} items, all already on your server'
          : 'Uploaded ${s.uploaded} new item${s.uploaded == 1 ? '' : 's'}',
      _ => '${s.done} of ${s.found}',
    };

/// Tooltip for the compact toolbar button.
String backupTooltip(BackupState s) => switch (s.phase) {
      BackupPhase.verifying =>
        'Checking ${s.done} of ${s.found} — nothing to upload',
      BackupPhase.uploading => 'Backing up ${s.done} of ${s.found}',
      BackupPhase.scanning => 'Scanning camera roll',
      _ => 'Back up to your Vault',
    };

/// Verifying gets a sync glyph rather than an upload arrow — the icon is the
/// fastest-read part of the status, so it has to agree with the words.
IconData backupStatusIcon(BackupState s) => switch (s.phase) {
      BackupPhase.done => Icons.cloud_done_outlined,
      BackupPhase.error => Icons.cloud_off_outlined,
      BackupPhase.idle => Icons.cloud_outlined,
      BackupPhase.verifying => Icons.cloud_sync_outlined,
      _ => Icons.cloud_upload_outlined,
    };
