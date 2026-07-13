import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'core/logging/vault_log.dart';
import 'core/platform/file_selector_access.dart';
import 'core/platform/platform_info.dart';
import 'core/platform/platform_services.dart';
import 'core/platform/window_setup.dart';
import 'core/services/service_registry.dart';
import 'shell/widgets/feature_error_view.dart';

Future<void> main() async {
  // Run inside a guarded zone so uncaught async errors are logged, not lost.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // A generous image cache keeps media thumbnails decoded while scrolling a
    // large library, avoiding re-decode flicker on scroll-back.
    PaintingBinding.instance.imageCache
      ..maximumSize = 2000
      ..maximumSizeBytes = 400 << 20; // 400 MB

    await VaultLog.init();
    VaultLog.installErrorHandlers();

    // Background audio (lock-screen controls + playback when app is
    // backgrounded). Mobile-only — the plugin isn't supported on desktop, where
    // music still plays via plain just_audio.
    if (isAndroidOrIOS) {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'dev.vault.audio',
        androidNotificationChannelName: 'Vault playback',
        androidNotificationOngoing: true,
      );
    }

    // Contain widget-build failures: a crashing feature's subtree is replaced
    // by a friendly panel instead of the red/white screen. (The failure itself
    // is logged via FlutterError.onError, installed above.)
    ErrorWidget.builder = (details) => FeatureErrorView(details: details);

    await setupDesktopWindow();

    runApp(
      ProviderScope(
        overrides: [
          serviceRegistryProvider.overrideWithValue(vaultServices),
          fileSystemAccessProvider
              .overrideWithValue(const FileSelectorAccess()),
        ],
        child: const VaultApp(),
      ),
    );
  }, (error, stack) {
    VaultLog.tag('zone').fatal('Uncaught error', error: error, stackTrace: stack);
  });
}
