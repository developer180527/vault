import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions/vault_action.dart';
import '../../core/platform/design/adaptive_icons.dart';

/// Renders a list of [VaultAction]s as toolbar buttons, overflowing into a "⋯"
/// menu past [maxVisible]. Hidden actions (failed `isEnabled`, i.e. a missing
/// capability) are dropped entirely. Shared by the desktop content toolbar and
/// the mobile app bar so the same actions appear on both.
class ActionBar extends ConsumerWidget {
  const ActionBar({super.key, required this.actions, this.maxVisible = 3});

  final List<VaultAction> actions;
  final int maxVisible;

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
          IconButton(
            tooltip: a.label,
            icon: AdaptiveIcon(a.icon),
            onPressed: () => a.onInvoke(context, ref),
          ),
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
            builder: (context, controller, _) => IconButton(
              tooltip: 'More',
              icon: const Icon(Icons.more_horiz),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            ),
          ),
      ],
    );
  }
}
