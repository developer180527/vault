import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/auth/session.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/logging/vault_log.dart';
import '../../../core/platform/platform_info.dart';
import '../../media/data/media_providers.dart';
import 'backup_core.dart';
import 'backup_engine.dart' show autoBackupPrefProvider;

/// TRUE background photo backup — runs the same [runBackupCore] pass without
/// the app open, via Android WorkManager (periodic) and iOS BGProcessingTask.
///
/// The catch that shapes this file: the OS runs the callback in a SEPARATE
/// Flutter isolate with no widget tree and none of the app's providers. So the
/// dispatcher stands up its OWN [ProviderContainer], resolves the persisted
/// session from secure storage, and reads only the providers backup needs
/// (session, http client, media library) — never playback/UI, which would try
/// to spin up an AudioPlayer in a headless isolate.
///
/// Wi-Fi + healthy-battery/storage constraints keep a big camera roll from
/// draining data or battery; a time budget stops a run before the OS window
/// closes, and the on-disk ledger makes a truncated run resume cleanly next
/// time.

/// Task identifiers. On iOS the unique name MUST match an entry in
/// Info.plist's BGTaskSchedulerPermittedIdentifiers.
const _iosTaskId = 'dev.vault.backup.processing';
const _androidUniqueName = 'vault.photobackup.periodic';
const _androidTaskName = 'photoBackup';

/// One background window's wall-clock cap — leave headroom before the OS
/// reclaims the isolate. The ledger persists progress, so the next window
/// continues where this one stopped.
const _bgBudget = Duration(minutes: 4);

/// The background-isolate entrypoint. Registered with WorkManager at init;
/// the OS calls it in a fresh isolate.
@pragma('vm:entry-point')
void backupCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final log = VaultLog.tag('bgbackup');
    final container = ProviderContainer();
    try {
      final session = await container.read(sessionProvider.future);
      if (session == null) {
        log.info('bg backup skipped: not connected');
        return true; // nothing to do — success, not a retry
      }
      final library = container.read(localMediaLibraryProvider);
      if (!library.isSupported) return true;

      final ledger = await BackupLedger.open(
          '${session.serverHost}_${session.deviceId}');
      final outcome = await runBackupCore(
        photos: container.read(vaultClientProvider).photos,
        library: library,
        ledger: ledger,
        log: log,
        budget: _bgBudget,
      );
      log.info('bg backup pass done', fields: {
        'found': outcome.found,
        'done': outcome.done,
        'failed': outcome.failed,
        'budgetHit': outcome.budgetHit,
      });
      // iOS BGTasks are one-shot: re-arm for the next window from within the
      // run (Android's periodic task re-fires on its own).
      if (isIOS) await scheduleBackgroundBackup();
      return true;
    } catch (e, s) {
      log.error('bg backup failed', error: e, stackTrace: s);
      return false; // let WorkManager retry with backoff
    } finally {
      container.dispose();
    }
  });
}

/// Initialize the WorkManager plugin (mobile only). Call once from main().
Future<void> initBackgroundBackup() async {
  if (!isAndroidOrIOS) return;
  await Workmanager().initialize(backupCallbackDispatcher);
}

/// Wi-Fi-only, don't-run-when-struggling constraints — photo backup is heavy.
Constraints _constraints() => Constraints(
      networkType: NetworkType.unmetered,
      requiresBatteryNotLow: true,
      requiresStorageNotLow: true,
    );

/// Arm the OS to run backup in the background. Idempotent: safe to call on
/// every launch (which iOS needs, since its scheduled tasks are consumed once
/// they run).
Future<void> scheduleBackgroundBackup() async {
  if (!isAndroidOrIOS) return;
  // Guarded: the plugin channel is absent in unit/widget tests and could be
  // flaky on-device; a scheduling failure must never bubble into UI build.
  try {
    if (isIOS) {
      await Workmanager().registerProcessingTask(
        _iosTaskId,
        _iosTaskId,
        constraints: _constraints(),
      );
    } else {
      await Workmanager().registerPeriodicTask(
        _androidUniqueName,
        _androidTaskName,
        frequency: const Duration(hours: 6),
        constraints: _constraints(),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
    }
  } catch (e) {
    VaultLog.tag('bgbackup').warn('schedule failed', fields: {'err': '$e'});
  }
}

/// Cancel the scheduled background backup (auto-backup turned off).
Future<void> cancelBackgroundBackup() async {
  if (!isAndroidOrIOS) return;
  try {
    await Workmanager()
        .cancelByUniqueName(isIOS ? _iosTaskId : _androidUniqueName);
  } catch (e) {
    VaultLog.tag('bgbackup').warn('cancel failed', fields: {'err': '$e'});
  }
}

/// Keeps the OS schedule in sync with the auto-backup preference — watched
/// once high in the tree so it (re)arms on every launch and reacts to toggles.
final backgroundBackupSchedulerProvider = Provider<void>((ref) {
  if (!isAndroidOrIOS) return;
  final on = ref.watch(autoBackupPrefProvider).asData?.value ?? false;
  if (on) {
    scheduleBackgroundBackup();
  } else {
    cancelBackgroundBackup();
  }
});
