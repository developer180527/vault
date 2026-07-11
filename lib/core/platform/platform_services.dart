import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background_runner.dart';
import 'file_system_access.dart';
import 'media_codec.dart';
import 'notifications.dart';

/// The platform ports, exposed as providers so shared business logic depends
/// only on the interfaces — never on `dart:io`, plugins, or a specific host.
///
/// Each defaults to a safe stub so the app runs everywhere today. A host binds
/// its real implementation by overriding the provider at the `ProviderScope`
/// root, e.g. in `main.dart`:
///
/// ```dart
/// ProviderScope(overrides: [
///   backgroundRunnerProvider.overrideWithValue(WorkManagerRunner()),
///   fileSystemAccessProvider.overrideWithValue(MobileFs()),
///   ...
/// ]);
/// ```
///
/// The desktop app and the headless daemon are just two more hosts binding
/// their own implementations to this same set of ports.

final backgroundRunnerProvider = Provider<BackgroundRunner>((ref) {
  final runner = StubBackgroundRunner();
  ref.onDispose(runner.dispose);
  return runner;
});

final fileSystemAccessProvider =
    Provider<FileSystemAccess>((ref) => const StubFileSystemAccess());

final mediaCodecProvider =
    Provider<MediaCodec>((ref) => const StubMediaCodec());

final notificationsProvider =
    Provider<Notifications>((ref) => const StubNotifications());

/// Device decode support, probed once and cached. Feature code watches this to
/// choose direct-play vs transcode via [planPlayback].
final mediaSupportProvider = FutureProvider<MediaSupport>(
    (ref) => ref.watch(mediaCodecProvider).probe());
