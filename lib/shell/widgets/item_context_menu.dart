import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions/vault_action.dart';
import '../../core/platform/haptics.dart';
import 'context_menu.dart';

/// Wraps a widget so it exposes context actions the way each platform expects:
/// **right-click** on desktop, **long-press** on mobile. The menu appears
/// exactly at the pointer with no animation. Used for file/folder rows and,
/// via [ContextMenuRegion], for empty space.
class ItemContextMenu extends ConsumerWidget {
  const ItemContextMenu({
    super.key,
    required this.actions,
    required this.child,
  });

  final List<VaultAction> actions;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ContextMenuRegion(
      actions: actions,
      behavior: HitTestBehavior.deferToChild,
      child: child,
    );
  }
}

/// Region that opens a context menu on secondary-tap / long-press at the exact
/// pointer position. [behavior] lets callers choose whether empty space inside
/// counts (translucent) or only the child's painted area (deferToChild).
class ContextMenuRegion extends ConsumerWidget {
  const ContextMenuRegion({
    super.key,
    required this.actions,
    required this.child,
    this.behavior = HitTestBehavior.deferToChild,
  });

  final List<VaultAction> actions;
  final Widget child;
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (actions.isEmpty) return child;
    void open(Offset position) => showContextMenu(
          context: context,
          ref: ref,
          globalPosition: position,
          actions: actions,
        );
    // Screen readers can't long-press/right-click: expose the menu as an
    // explicit custom action ("Show options" in the VoiceOver/TalkBack rotor),
    // anchored to the region's center.
    return Semantics(
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Show options'): () {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null || !box.attached) return;
          open(box.localToGlobal(box.size.center(Offset.zero)));
        },
      },
      child: GestureDetector(
        behavior: behavior,
        // -Up, not -Down: tap-down callbacks fire speculatively on EVERY
        // recognizer still competing in the gesture arena, so a right-click on
        // an item opened both the item menu and the enclosing empty-space menu.
        // Up callbacks only fire for the arena winner (the innermost region).
        onSecondaryTapUp: (d) => open(d.globalPosition),
        onLongPressStart: (d) {
          VaultHaptics.impact();
          open(d.globalPosition);
        },
        child: child,
      ),
    );
  }
}
