import 'package:flutter/foundation.dart';

/// Which platform design language the UI should speak. Business logic is
/// identical everywhere; only the *representation* switches on this — icons
/// (SF Symbols vs Material), surface materials (liquid glass vs elevated
/// Material), and per-platform layout accents.
enum DesignLanguage {
  /// iOS / macOS: SF Symbol glyphs, glass surfaces, Apple-style chrome.
  apple,

  /// Android, Windows, Linux, web: Material 3.
  material,
}

/// The design language for this device. A static property (not a widget
/// lookup) because it never changes at runtime and non-widget code (icon
/// resolution, action definitions) needs it too.
DesignLanguage get designLanguage {
  if (kIsWeb) return DesignLanguage.material;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => DesignLanguage.apple,
    _ => DesignLanguage.material,
  };
}
