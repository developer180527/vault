import 'package:flutter/foundation.dart';

/// Centralized form-factor / platform predicates so shell and chrome code
/// don't re-derive them (and don't touch dart:io, which breaks on web).

/// Native desktop OS (not web, not mobile). These always use the sidebar
/// shell and can host a custom, draggable title bar.
bool get isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

/// macOS specifically — its window controls ("traffic lights") sit top-left,
/// so a custom title bar must reserve space there.
bool get isMacOS =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Mobile OSes, which have a system photo library and scoped media permissions.
bool get isAndroidOrIOS =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Windows/Linux native — we draw our own min/max/close caption buttons on
/// the right of the custom title bar.
bool get isWindowsOrLinux =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);
