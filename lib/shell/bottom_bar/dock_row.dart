import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/platform/design/adaptive_icons.dart';
import '../../core/services/service_registry.dart';
import 'metrics.dart';

/// The dock slots with a single selection capsule that SLIDES between them,
/// like the native tab bar's lozenge — rather than each slot lighting up its
/// own highlight.
class DockRow extends StatelessWidget {
  const DockRow({
    super.key,
    required this.dock,
    required this.selectedIndex,
    required this.onTap,
    this.labelOpacity = 1,
  });

  final List<ServiceDefinition> dock;

  /// -1 = nothing selected (the You page is active).
  final int selectedIndex;
  final ValueChanged<ServiceDefinition> onTap;

  /// 1 = labels shown, 0 = icon-only (the dock compacts to icons while the
  /// mini-player squeezes in beside it). Values between animate the fade.
  final double labelOpacity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (dock.isEmpty) return const SizedBox.shrink();
    final n = dock.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final slotWidth = width / n;
        // Capsule fits WITHIN its slot (never wider), so it can't spill past the
        // slot into the pill's rounded cap and get clipped. A small inset
        // (top/bottom 10, ~4px side gap) also gives the corners clearance.
        const vInset = 10.0;
        final capsuleHeight = kDockHeight - vInset * 2;
        final capsuleWidth = math.max(0.0, slotWidth - 4);
        final i = selectedIndex.clamp(0, n - 1);
        final left = i * slotWidth + (slotWidth - capsuleWidth) / 2;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 340),
              curve: Curves.easeOutCubic,
              left: left,
              top: vInset,
              width: capsuleWidth,
              height: capsuleHeight,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: selectedIndex < 0 ? 0 : 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(capsuleHeight / 2),
                  ),
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < n; i++)
                  Expanded(
                    child: DockItem(
                      service: dock[i],
                      selected: i == selectedIndex,
                      onTap: () => onTap(dock[i]),
                      labelOpacity: labelOpacity,
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// One dock slot: icon + label. The selection capsule is drawn by [DockRow].
class DockItem extends StatelessWidget {
  const DockItem({
    super.key,
    required this.service,
    required this.selected,
    required this.onTap,
    this.labelOpacity = 1,
  });

  final ServiceDefinition service;
  final bool selected;
  final VoidCallback onTap;
  final double labelOpacity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    // GestureDetector, not InkWell: native tab bars have no ripple/highlight.
    // The raw detector has NO semantics of its own, so declare the tab role
    // explicitly — otherwise the whole dock is invisible to screen readers.
    return Semantics(
      button: true,
      selected: selected,
      label: '${service.label} tab',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ExcludeSemantics(
              child: AdaptiveIcon(
                service.icon,
                selected: selected,
                size: 22,
                color: color,
              ),
            ),
            // Label collapses (height + opacity) to icon-only as the mini-player
            // squeezes in — so a narrow dock never shows clipped text.
            if (labelOpacity > 0.01)
              ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: labelOpacity,
                  child: Opacity(
                    opacity: labelOpacity.clamp(0.0, 1.0),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: ExcludeSemantics(
                        child: Text(
                          service.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: color,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
