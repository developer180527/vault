import 'package:flutter/services.dart';

import 'platform_info.dart';

/// Haptic feedback abstraction. Every method is a safe no-op on desktop and
/// web, so call sites never need platform checks.
abstract final class VaultHaptics {
  /// Light tick — e.g. a nav icon snapping onto the selector pointer.
  static void selection() {
    if (isAndroidOrIOS) HapticFeedback.selectionClick();
  }

  /// Firmer pulse — e.g. a long-press revealing context actions.
  static void impact() {
    if (isAndroidOrIOS) HapticFeedback.mediumImpact();
  }
}
