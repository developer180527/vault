import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/platform/platform_info.dart';
import 'task_status_button.dart';

/// Custom, full-width title bar for the desktop shell: an in-window menu bar
/// (File / Edit / View …) like the mockup, with the background-task status on
/// the right. On macOS it reserves space for the traffic lights; on
/// Windows/Linux it draws its own caption buttons. The empty middle is a
/// drag-to-move handle for the window.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({super.key});

  static const double height = 44;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bar = Container(
      height: height,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          // Reserve room for macOS traffic lights.
          if (isMacOS) const SizedBox(width: 78),
          const SizedBox(width: 4),
          const _MenuBar(),
          const Expanded(child: _DragArea()),
          const TaskStatusButton(),
          if (isWindowsOrLinux) const _CaptionButtons(),
          const SizedBox(width: 6),
        ],
      ),
    );
    return bar;
  }
}

/// Drag surface — moving the pointer here moves the native window. Falls back
/// to an inert container on web/mobile where window dragging is unavailable.
class _DragArea extends StatelessWidget {
  const _DragArea();

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return const SizedBox.expand();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async =>
          await windowManager.isMaximized()
              ? windowManager.unmaximize()
              : windowManager.maximize(),
      child: const SizedBox.expand(),
    );
  }
}

class _MenuBar extends StatelessWidget {
  const _MenuBar();

  @override
  Widget build(BuildContext context) {
    // MenuBar gives real menu-bar behavior: click to open, hover to switch,
    // keyboard traversal. Actions are stubs until features land.
    return MenuBar(
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      children: [
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              shortcut:
                  const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
              onPressed: () {},
              child: const Text('New Folder'),
            ),
            MenuItemButton(onPressed: () {}, child: const Text('Upload…')),
            const Divider(),
            MenuItemButton(onPressed: () {}, child: const Text('Close Window')),
          ],
          child: const Text('File'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(onPressed: () {}, child: const Text('Cut')),
            MenuItemButton(onPressed: () {}, child: const Text('Copy')),
            MenuItemButton(onPressed: () {}, child: const Text('Paste')),
            const Divider(),
            MenuItemButton(onPressed: () {}, child: const Text('Select All')),
          ],
          child: const Text('Edit'),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(onPressed: () {}, child: const Text('As Grid')),
            MenuItemButton(onPressed: () {}, child: const Text('As List')),
            const Divider(),
            MenuItemButton(onPressed: () {}, child: const Text('Reload')),
          ],
          child: const Text('View'),
        ),
      ],
    );
  }
}

/// Minimal min / max / close controls for platforms whose window controls we
/// hid (Windows, Linux). macOS keeps its native traffic lights.
class _CaptionButtons extends StatelessWidget {
  const _CaptionButtons();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _CaptionButton(
            icon: Icons.remove, onPressed: windowManager.minimize),
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
