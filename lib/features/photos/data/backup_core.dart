import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/client/vault_client.dart';
import '../../../core/logging/vault_log.dart';
import '../../media/data/local_media_library.dart';

/// Where the backup engine is in its lifecycle.
enum BackupPhase { idle, scanning, uploading, done, error }

/// A progress tick emitted from [runBackupCore] — the UI-agnostic shape both
/// the foreground engine (→ [BackupState]) and the headless background task
/// consume.
class BackupTick {
  const BackupTick({
    required this.phase,
    this.found = 0,
    this.done = 0,
    this.failed = 0,
    this.current = '',
    this.error = '',
  });

  final BackupPhase phase;
  final int found;
  final int done;
  final int failed;
  final String current;
  final String error;
}

/// The result of one backup pass.
class BackupOutcome {
  const BackupOutcome({
    required this.found,
    required this.done,
    required this.failed,
    this.error = '',
    this.budgetHit = false,
  });

  final int found;
  final int done;
  final int failed;
  final String error;

  /// True when the run stopped early because it hit its time budget (a
  /// background window ending) — not a failure, just "more to do next time".
  final bool budgetHit;
}

/// The device-local record of what's already backed up: asset id → sha256.
/// Scoped per server+device (like listing snapshots) so switching servers
/// re-verifies rather than assuming. The ledger is an OPTIMIZATION — losing
/// it costs re-hashing, never re-uploading (the server's hash check dedupes).
class BackupLedger {
  BackupLedger(this._file, this._entries);

  final File _file;
  final Map<String, String> _entries;
  int _dirty = 0;

  static Future<BackupLedger> open(String scope) async {
    final dir = await getApplicationSupportDirectory();
    final safe = scope.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_');
    final f = File('${dir.path}/backup_ledger_$safe.json');
    var entries = <String, String>{};
    try {
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString());
        entries = {
          for (final e in (raw as Map).entries) e.key as String: '${e.value}',
        };
      }
    } catch (_) {
      // Corrupt ledger = cold start; the server check keeps it correct.
    }
    return BackupLedger(f, entries);
  }

  bool contains(String assetId) => _entries.containsKey(assetId);

  Future<void> record(String assetId, String hash) async {
    _entries[assetId] = hash;
    // Write-behind: persist every 25 records; the run flushes at the end.
    if (++_dirty >= 25) await flush();
  }

  /// Drops entries whose content the server no longer holds, and reports how
  /// many were dropped. The ledger is a cache of "already uploaded" — if the
  /// server lost a file (or its row), the ledger's claim is stale and the
  /// item must be eligible for upload again. Without this, one lost row meant
  /// one photo silently never backed up again.
  int reconcile(Set<String> serverHashes) {
    final stale = [
      for (final e in _entries.entries)
        if (!serverHashes.contains(e.value)) e.key,
    ];
    for (final k in stale) {
      _entries.remove(k);
    }
    return stale.length;
  }

  Future<void> flush() async {
    _dirty = 0;
    try {
      await _file.writeAsString(jsonEncode(_entries));
    } catch (_) {
      // Best-effort; the server check keeps correctness.
    }
  }
}

/// THE camera-roll backup pass, headless and provider-free: reconcile the
/// ledger against the server, enumerate the roll, hash new items, ask the
/// server what's missing, upload exactly that — sequentially. Runs identically
/// in the foreground (wrapped by [BackupEngine] for the status UI + playback
/// throttling) and in a background isolate (the WorkManager/BGTask callback).
///
/// - [onTick]: progress for a UI, if any. The background task passes null.
/// - [onBatch]: fired after each server round-trip so a live listing can
///   refresh. Background passes null.
/// - [beforeUpload]: awaited before every upload — the foreground yields here
///   while music is playing so the stream keeps its Wi-Fi airtime.
/// - [budget]: wall-clock cap; when exceeded, no new uploads START (the current
///   one finishes). Background windows are short, so this avoids the OS
///   force-killing us mid-transfer. The ledger makes a truncated run safe.
Future<BackupOutcome> runBackupCore({
  required PhotosApi photos,
  required LocalMediaLibrary library,
  required BackupLedger ledger,
  required VaultLogger log,
  void Function(BackupTick tick)? onTick,
  void Function()? onBatch,
  Future<void> Function()? beforeUpload,
  Duration? budget,
}) async {
  final deadline = budget == null ? null : DateTime.now().add(budget);
  bool overBudget() => deadline != null && DateTime.now().isAfter(deadline);

  final access = await library.requestAccess();
  if (access == MediaAccess.denied || access == MediaAccess.unavailable) {
    log.warn('backup aborted: no photo access', fields: {'state': '$access'});
    onTick?.call(const BackupTick(
        phase: BackupPhase.error,
        error: 'Photo library access is not granted.'));
    return const BackupOutcome(
        found: 0, done: 0, failed: 0, error: 'no photo access');
  }

  onTick?.call(const BackupTick(phase: BackupPhase.scanning));

  // Reconcile the ledger against what the server ACTUALLY holds before
  // trusting it to skip anything. Cheap (a couple of paginated reads) and it
  // makes the whole backup self-healing: any item the server lost becomes
  // eligible for upload again on the very next run.
  try {
    final serverHashes = <String>{};
    for (var offset = 0;; offset += 500) {
      final page = await photos.list(limit: 500, offset: offset);
      serverHashes.addAll(page.photos.map((p) => p.hash));
      if (page.photos.length < 500) break;
    }
    final dropped = ledger.reconcile(serverHashes);
    if (dropped > 0) {
      await ledger.flush();
      log.warn(
          'ledger reconciled — server missing items thought backed up; '
          'they will re-upload',
          fields: {'dropped': dropped, 'server_has': serverHashes.length});
    }
  } catch (e) {
    // Reconciliation is an optimization guard, not a gate.
    log.debug('ledger reconcile skipped', fields: {'err': '$e'});
  }

  // Full enumeration, newest first — page until a short page.
  final todo = <MediaItem>[];
  var found = 0;
  for (var page = 0;; page++) {
    const pageSize = 120;
    final items = await library.loadPage(
        filter: MediaFilter.all, page: page, pageSize: pageSize);
    found += items.length;
    todo.addAll(items.where((i) => !ledger.contains(i.id)));
    onTick?.call(BackupTick(
        phase: BackupPhase.scanning, found: found, done: found - todo.length));
    if (items.length < pageSize) break;
  }

  var done = found - todo.length;
  var failed = 0;
  var budgetHit = false;
  log.info('camera roll scanned', fields: {
    'found': found,
    'already_backed_up': done,
    'to_process': todo.length,
  });

  // Chunked: hash a batch, one round-trip for "what's missing", upload the gap.
  const chunk = 40;
  outer:
  for (var start = 0; start < todo.length; start += chunk) {
    if (overBudget()) {
      budgetHit = true;
      break;
    }
    final batch = todo.sublist(
        start, start + chunk > todo.length ? todo.length : start + chunk);

    // Hash: stream each original from disk (never whole-file in memory).
    final hashed = <(MediaItem, File, String)>[];
    for (final item in batch) {
      try {
        final f = await item.asset.originFile;
        if (f == null) throw Exception('original unavailable');
        final digest = await sha256.bind(f.openRead()).first;
        hashed.add((item, f, digest.toString()));
      } catch (e) {
        failed++;
        log.debug('hash failed', fields: {'id': item.id, 'err': '$e'});
      }
    }
    if (hashed.isEmpty) {
      onTick?.call(BackupTick(
          phase: BackupPhase.uploading, found: found, done: done, failed: failed));
      continue;
    }

    final missing = (await photos.checkMissing([
      for (final (_, _, h) in hashed) h,
    ]))
        .toSet();
    log.info('server check',
        fields: {'batch': hashed.length, 'missing': missing.length});
    onBatch?.call();

    for (final (item, file, hash) in hashed) {
      if (!missing.contains(hash)) {
        // Already on the server (e.g. this user's other device) — record it.
        await ledger.record(item.id, hash);
        done++;
        onTick?.call(BackupTick(
            phase: BackupPhase.uploading,
            found: found,
            done: done,
            failed: failed));
        continue;
      }
      if (overBudget()) {
        budgetHit = true;
        break outer;
      }
      // Filename: the asset title when the OS gives one, else the origin
      // file's own basename. NEVER a made-up extension — iOS often returns a
      // null title in release builds, and the server (correctly) refuses files
      // it can't classify; a `.bin` fallback 400'd entire rolls.
      var name = item.asset.title ?? '';
      if (!name.contains('.')) name = file.path.split('/').last;

      onTick?.call(BackupTick(
          phase: BackupPhase.uploading,
          found: found,
          done: done,
          failed: failed,
          current: name));
      if (beforeUpload != null) await beforeUpload();

      try {
        final ack = await photos.upload(
            path: file.path,
            name: name,
            hash: hash,
            takenAt: item.asset.createDateTime);
        log.info('backed up', fields: {
          'name': name,
          'bytes': ack.size,
          'server_id': ack.id,
          'hash_verified': ack.hash == hash,
        });
        await ledger.record(item.id, hash);
        done++;
      } catch (e) {
        failed++;
        log.warn('upload failed', fields: {'name': name, 'err': '$e'});
      }
      onTick?.call(BackupTick(
          phase: BackupPhase.uploading,
          found: found,
          done: done,
          failed: failed));
    }
  }

  await ledger.flush();
  onBatch?.call();
  return BackupOutcome(
      found: found, done: done, failed: failed, budgetHit: budgetHit);
}
