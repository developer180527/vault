import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/platform/platform_info.dart';

/// Custom title bar for the native-desktop frameless window. Deliberately has
/// NO menu bar — File/Edit/View actions were relocated to the per-service
/// content toolbar, item context menus, and the Cmd-K command palette (so they
/// also exist on mobile). This bar only carries window affordances: a
/// drag-to-move region, macOS traffic-light spacing / Windows-Linux caption
/// buttons, and the background-task status.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({super.key});

  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: height,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          if (isMacOS) const SizedBox(width: 78),
          const Expanded(child: _DragArea()),
          if (isWindowsOrLinux) const _CaptionButtons(),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// Drag surface — moving the pointer here moves the native window; double-click
/// toggles maximize. Inert on web/mobile.
class _DragArea extends StatelessWidget {
  const _DragArea();

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return const SizedBox.expand();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async => await windowManager.isMaximized()
          ? windowManager.unmaximize()
          : windowManager.maximize(),
      child: const SizedBox.expand(),
    );
  }
}

/// min / max / close controls for platforms whose native controls we hid
/// (Windows, Linux). macOS keeps its traffic lights.
class _CaptionButtons extends StatelessWidget {
  const _CaptionButtons();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _CaptionButton(icon: Icons.remove, onPressed: windowManager.minimize),
        _CaptionButton(
          icon: Icons.crop_square,
          onPressed: () async => await windowManager.isMaximized()
              ? windowManager.unmaximize()
              : windowManager.maximize(),
        ),
        _CaptionButton(
            icon: Icons.close, onPressed: windowManager.close, danger: true),
      ],
    );
  }
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton(
      {required this.icon, required this.onPressed, this.danger = false});

  final IconData icon;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      iconSize: 16,
      visualDensity: VisualDensity.compact,
      hoverColor: danger ? Colors.red.withValues(alpha: 0.8) : null,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}
