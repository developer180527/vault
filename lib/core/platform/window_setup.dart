import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'platform_info.dart';

/// Configures the native desktop window for a custom title bar: hides the OS
/// title bar (we draw our own with File/Edit/View menus) while keeping the
/// macOS traffic-light buttons visible. No-op on web and mobile.
Future<void> setupDesktopWindow() async {
  if (!isDesktopPlatform) return;

  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: Size(1200, 800),
    minimumSize: Size(720, 520),
    center: true,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: true, // keep macOS traffic lights
    title: 'Vault',
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
