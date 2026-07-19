import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/session.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/logging/vault_log.dart';
import '../../../core/models/server_photo.dart';
import '../../../core/playback/playback_controller.dart';
import '../../media/data/media_providers.dart';
import 'backup_core.dart';

export 'backup_core.dart' show BackupPhase, BackupLedger, runBackupCore;

final _log = VaultLog.tag('backup');

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
    if (_running) return;
    if (!_available) {
      // Say WHY nothing happens — a silent no-op here cost a debugging round.
      _log.info('backup not started', fields: {
        'connected': ref.read(sessionProvider).asData?.value != null,
        'supported': ref.read(localMediaLibraryProvider).isSupported,
      });
      return;
    }
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
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    final ledger = await BackupLedger.open(
      '${session.serverHost}_${session.deviceId}',
    );
    final outcome = await runBackupCore(
      photos: ref.read(vaultClientProvider).photos,
      library: ref.read(localMediaLibraryProvider),
      ledger: ledger,
      log: _log,
      onTick: (t) => state = state.copyWith(
        phase: t.phase,
        found: t.found,
        done: t.done,
        failed: t.failed,
        // null keeps the previous value — don't blank the current filename or
        // error between per-item ticks.
        current: t.current.isEmpty ? null : t.current,
        error: t.error.isEmpty ? null : t.error,
      ),
      // Keep the "items on the server" figure live as batches land.
      onBatch: () => ref.invalidate(backupListingProvider),
      // Music first, backup second: while audio is actively playing, yield
      // between uploads so the stream keeps its Wi-Fi airtime (continuous
      // uploads starved the audio TCP acks and stuttered playback).
      beforeUpload: () async {
        if (ref.read(playbackProvider).currentAudio != null &&
            ref.read(playbackProvider.notifier).player.playing) {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
      },
    );
    ref.invalidate(backupListingProvider);
    state = state.copyWith(
      phase: outcome.failed > 0 && outcome.done < outcome.found
          ? BackupPhase.error
          : BackupPhase.done,
      found: outcome.found,
      done: outcome.done,
      failed: outcome.failed,
      current: '',
      error: outcome.failed > 0
          ? '${outcome.failed} item(s) failed — will retry next run.'
          : '',
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
