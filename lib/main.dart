import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/platform/window_setup.dart';
import 'core/services/service_registry.dart';
import 'shell/widgets/feature_error_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Contain widget-build failures: a crashing feature's subtree is replaced by
  // a friendly panel instead of the red/white screen, keeping the rest alive.
  ErrorWidget.builder = (details) => FeatureErrorView(details: details);

  await setupDesktopWindow();
  runApp(
    ProviderScope(
      overrides: [
        serviceRegistryProvider.overrideWithValue(vaultServices),
      ],
      child: const VaultApp(),
    ),
  );
}
