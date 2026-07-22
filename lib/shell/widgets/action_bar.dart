import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions/vault_action.dart';
import '../../core/platform/design/adaptive_icons.dart';

/// Renders a list of [VaultAction]s as toolbar buttons, overflowing into a "⋯"
/// menu past [maxVisible]. Hidden actions (failed `isEnabled`, i.e. a missing
/// capability) are dropped entirely. Shared by the desktop content toolbar and
/// the mobile app bar so the same actions appear on both.
///
/// [floating] wraps each button in a blurred glass chip so it reads as a
/// distinct object floating over full-bleed content (the mobile header), rather
/// than a flat icon on a toolbar fill (the desktop toolbar, [floating] false).
class ActionBar extends ConsumerWidget {
  const ActionBar({
    super.key,
    required this.actions,
    this.maxVisible = 3,
    this.floating = false,
  });

  final List<VaultAction> actions;
  final int maxVisible;
  final bool floating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibleActions = [
      for (final a in actions)
        if (a.enabled(ref)) a,
    ];
    if (visibleActions.isEmpty) return const SizedBox.shrink();

    final inline = visibleActions.take(maxVisible).toList();
    final overflow = visibleActions.skip(maxVisible).toList();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final a in inline)
          _wrap(IconButton(
            tooltip: a.label,
            icon: AdaptiveIcon(a.icon),
            onPressed: () => a.onInvoke(context, ref),
          )),
        if (overflow.isNotEmpty)
          MenuAnchor(
            menuChildren: [
              for (final a in overflow)
                MenuItemButton(
                  leadingIcon: AdaptiveIcon(a.icon, size: 18),
                  onPressed: () => a.onInvoke(context, ref),
                  child: Text(a.label),
                ),
            ],
            builder: (context, controller, _) => _wrap(IconButton(
              tooltip: 'More',
              icon: const Icon(Icons.more_horiz),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            )),
          ),
      ],
    );
  }

  Widget _wrap(Widget button) =>
      floating ? _GlassChip(child: button) : button;
}

/// A circular blurred chip that lets an icon float legibly over any content —
/// the header's answer to "no bar, but the buttons still need to be readable".
class _GlassChip extends StatelessWidget {
  const _GlassChip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.surface.withValues(alpha: 0.42),
              border: Border.all(
                color: scheme.onSurface.withValues(alpha: 0.08),
                width: 0.5,
              ),
            ),
            child: SizedBox(
              width: 40,
              height: 40,
              child: IconButtonTheme(
                data: const IconButtonThemeData(
                  style: ButtonStyle(
                    padding: WidgetStatePropertyAll(EdgeInsets.zero),
                    minimumSize: WidgetStatePropertyAll(Size(40, 40)),
                  ),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
