import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/session.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/logging/vault_log.dart';
import '../../../core/models/server_photo.dart';
import '../../media/data/local_media_library.dart';
import '../../media/data/media_providers.dart';

final _log = VaultLog.tag('backup');

/// Where the backup engine is in its lifecycle.
enum BackupPhase { idle, scanning, uploading, done, error }

/// A snapshot of backup progress for the status UI.
class BackupState {
  const BackupState({
    this.phase = BackupPhase.idle,
    this.found = 0,
    this.done = 0,
    this.failed = 0,
    this.current = '',
    this.error = '',
    this.lastRun,
  });

  final BackupPhase phase;

  /// Camera-roll items discovered that belong in the backup.
  final int found;

  /// Items confirmed on the server this run (uploaded or already there).
  final int done;

  final int failed;

  /// Filename currently uploading (uploading phase only).
  final String current;

  final String error;
  final DateTime? lastRun;

  BackupState copyWith({
    BackupPhase? phase,
    int? found,
    int? done,
    int? failed,
    String? current,
    String? error,
    DateTime? lastRun,
  }) => BackupState(
    phase: phase ?? this.phase,
    found: found ?? this.found,
    done: done ?? this.done,
    failed: failed ?? this.failed,
    current: current ?? this.current,
    error: error ?? this.error,
    lastRun: lastRun ?? this.lastRun,
  );
}

/// Whether automatic backup is enabled (persisted per device).
class AutoBackupPref extends AsyncNotifier<bool> {
  static const _key = 'photos.auto_backup_v1';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> set(bool on) async {
    state = AsyncData(on);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, on);
  }
}

final autoBackupPrefProvider = AsyncNotifierProvider<AutoBackupPref, bool>(
  AutoBackupPref.new,
);

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
    // Write-behind: persist every 25 records; run() flushes at the end.
    if (++_dirty >= 25) await flush();
  }

  Future<void> flush() async {
    _dirty = 0;
    try {
      await _file.writeAsString(jsonEncode(_entries));
    } catch (e) {
      _log.debug('ledger write failed', fields: {'err': '$e'});
    }
  }
}

/// The camera-roll backup engine: enumerate → hash → ask the server what's
/// missing → upload exactly that, sequentially. One instance app-wide;
/// [run] is re-entrant-safe (a second call while running is a no-op).
class BackupEngine extends Notifier<BackupState> {
  bool _running = false;

  @override
  BackupState build() => const BackupState();

  /// True when a run can do anything at all: connected + supported platform.
  bool get _available {
    final connected = ref.read(sessionProvider).asData?.value != null;
    return connected && ref.read(localMediaLibraryProvider).isSupported;
  }

  Future<void> run() async {
    if (_running || !_available) return;
    _running = true;
    try {
      await _run();
    } catch (e) {
      _log.debug('backup run failed', fields: {'err': '$e'});
      state = state.copyWith(phase: BackupPhase.error, error: '$e');
    } finally {
      _running = false;
    }
  }

  Future<void> _run() async {
    final lib = ref.read(localMediaLibraryProvider);
    final access = await lib.requestAccess();
    if (access == MediaAccess.denied || access == MediaAccess.unavailable) {
      state = state.copyWith(
        phase: BackupPhase.error,
        error: 'Photo library access is not granted.',
      );
      return;
    }

    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    final ledger = await BackupLedger.open(
      '${session.serverHost}_${session.deviceId}',
    );
    final api = ref.read(vaultClientProvider).photos;

    state = const BackupState(phase: BackupPhase.scanning);

    // Full enumeration, newest first — page until a short page.
    final todo = <MediaItem>[];
    var found = 0;
    for (var page = 0; ; page++) {
      const pageSize = 120;
      final items = await lib.loadPage(
        filter: MediaFilter.all,
        page: page,
        pageSize: pageSize,
      );
      found += items.length;
      todo.addAll(items.where((i) => !ledger.contains(i.id)));
      state = state.copyWith(found: found, done: found - todo.length);
      if (items.length < pageSize) break;
    }

    var done = found - todo.length;
    var failed = 0;

    // Chunked: hash a batch, one round-trip for "what's missing", upload the
    // gap. Sequential uploads keep memory flat and the server unhammered.
    const chunk = 40;
    for (var start = 0; start < todo.length; start += chunk) {
      final batch = todo.sublist(
        start,
        start + chunk > todo.length ? todo.length : start + chunk,
      );

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
          _log.debug('hash failed', fields: {'id': item.id, 'err': '$e'});
        }
      }
      if (hashed.isEmpty) {
        state = state.copyWith(done: done, failed: failed);
        continue;
      }

      final missing = (await api.checkMissing([
        for (final (_, _, h) in hashed) h,
      ])).toSet();

      for (final (item, file, hash) in hashed) {
        if (!missing.contains(hash)) {
          // Already on the server (say, uploaded by this user's other
          // device) — record and move on.
          await ledger.record(item.id, hash);
          done++;
          state = state.copyWith(phase: BackupPhase.uploading, done: done);
          continue;
        }
        final name = item.asset.title ?? '${item.id}.bin';
        state = state.copyWith(phase: BackupPhase.uploading, current: name);
        try {
          await api.upload(
            path: file.path,
            name: name,
            hash: hash,
            takenAt: item.asset.createDateTime,
          );
          await ledger.record(item.id, hash);
          done++;
        } catch (e) {
          failed++;
          _log.debug('upload failed', fields: {'name': name, 'err': '$e'});
        }
        state = state.copyWith(done: done, failed: failed);
      }
    }

    await ledger.flush();
    state = state.copyWith(
      phase: failed > 0 && done < found ? BackupPhase.error : BackupPhase.done,
      found: found,
      done: done,
      failed: failed,
      current: '',
      error: failed > 0 ? '$failed item(s) failed — will retry next run.' : '',
      lastRun: DateTime.now(),
    );
  }
}

final backupEngineProvider = NotifierProvider<BackupEngine, BackupState>(
  BackupEngine.new,
);

/// The server-side backup listing (totals for the status card).
final backupListingProvider = FutureProvider<PhotoBackupListing>((ref) {
  if (ref.watch(sessionProvider).asData?.value == null) {
    return const PhotoBackupListing(photos: [], total: 0, totalBytes: 0);
  }
  return ref.watch(vaultClientProvider).photos.list(limit: 12);
});

/// Kick an automatic run when the app comes up connected with auto-backup on.
/// Watched once from the Photos page (and cheap to watch anywhere).
final autoBackupTriggerProvider = Provider<void>((ref) {
  final connected = ref.watch(sessionProvider).asData?.value != null;
  final auto = ref.watch(autoBackupPrefProvider).asData?.value ?? false;
  if (connected && auto) {
    // Post-frame: never run during provider build.
    Future.microtask(() => ref.read(backupEngineProvider.notifier).run());
  }
});
