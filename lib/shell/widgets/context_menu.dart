import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions/vault_action.dart';
import '../../core/platform/design/adaptive_icons.dart';

const double _menuWidth = 240;
const double _rowHeight = 40;

/// Shows a context menu **exactly at the pointer** with **no open animation**
/// (unlike Material's `showMenu`, which scales in and re-anchors). Used for
/// both item right-clicks and empty-space right-clicks, on desktop
/// (secondary-tap) and mobile (long-press). Clamps to stay on-screen.
Future<void> showContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Offset globalPosition,
  required List<VaultAction> actions,
}) {
  final available = [
    for (final a in actions)
      if (a.enabled(ref)) a,
  ];
  if (available.isEmpty) return Future.value();

  final overlay = Overlay.of(context, rootOverlay: true);
  final completer = Completer<void>();
  late OverlayEntry entry;

  void close() {
    if (entry.mounted) entry.remove();
    if (!completer.isCompleted) completer.complete();
  }

  entry = OverlayEntry(builder: (ctx) {
    final size = MediaQuery.of(ctx).size;
    final menuHeight = available.length * _rowHeight + 8;
    final left = globalPosition.dx.clamp(0.0, size.width - _menuWidth - 8);
    final top = globalPosition.dy.clamp(0.0, size.height - menuHeight - 8);

    return Stack(
      children: [
        // Dismiss barrier. GestureDetector for the extra secondary-tap close;
        // ModalBarrier inside for proper a11y (screen readers get a labeled,
        // dismissible surface instead of an invisible tap-trap).
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTap: close,
            child: ModalBarrier(
              onDismiss: close,
              semanticsLabel: 'Dismiss menu',
              barrierSemanticsDismissible: true,
              color: Colors.transparent,
            ),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          // Route semantics: announce as a menu and scope a11y focus into it.
          child: Semantics(
            scopesRoute: true,
            namesRoute: true,
            label: 'Options menu',
            explicitChildNodes: true,
            child: _ContextMenuBody(
              actions: available,
              onSelected: (a) {
                close();
                a.onInvoke(context, ref);
              },
            ),
          ),
        ),
      ],
    );
  });

  overlay.insert(entry);
  return completer.future;
}

class _ContextMenuBody extends StatelessWidget {
  const _ContextMenuBody({required this.actions, required this.onSelected});

  final List<VaultAction> actions;
  final ValueChanged<VaultAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      color: scheme.surfaceContainerHigh,
      child: SizedBox(
        width: _menuWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 4),
            for (final a in actions)
              // One merged, labeled button per row (icon is decorative).
              MergeSemantics(
                child: Semantics(
                  button: true,
                  child: InkWell(
                    onTap: () => onSelected(a),
                    child: SizedBox(
                      height: _rowHeight,
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          ExcludeSemantics(
                            child: AdaptiveIcon(a.icon,
                                size: 18,
                                color: a.isDestructive ? scheme.error : null),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              a.label,
                              style: a.isDestructive
                                  ? TextStyle(color: scheme.error)
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
