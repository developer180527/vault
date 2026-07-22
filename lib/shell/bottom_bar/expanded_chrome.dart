import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../core/platform/design/glass_surface.dart';
import '../../core/services/service_registry.dart';
import 'dock_row.dart';
import 'metrics.dart';
import 'mini_player_pill.dart';
import 'you_circle.dart';

/// The expanded chrome, one row: the dock pill, then (while a track plays) the
/// mini-player, then the detached You circle.
///
/// The mini-player doesn't fade in on top — it is SQUEEZED into being. One
/// controller drives a single choreographed move: the dock compresses to
/// [kDockPlayingFraction] of its width, the You circle shrinks
/// ([kYouExpanded] → [kYouShrunk]), and the pill grows into the gap that opens
/// between them (revealed by a widening clip, not a relocate). Reverse on stop.
class ExpandedChrome extends StatefulWidget {
  const ExpandedChrome({
    super.key,
    required this.hasTrack,
    required this.onUserPage,
    required this.dock,
    required this.currentId,
    required this.onOpen,
    required this.onCollapse,
  });

  final bool hasTrack;
  final bool onUserPage;
  final List<ServiceDefinition> dock;
  final String currentId;
  final void Function(String id) onOpen;
  final VoidCallback onCollapse;

  @override
  State<ExpandedChrome> createState() => _ExpandedChromeState();
}

class _ExpandedChromeState extends State<ExpandedChrome>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: kChromeAnim,
    value: widget.hasTrack ? 1 : 0, // already playing on mount → no entrance
  );

  // Built ONCE and reused every frame — the eased progress and the pill's
  // fade curve never change, so there's no reason to reallocate them per build.
  late final Animation<double> _t =
      CurvedAnimation(parent: _entrance, curve: kChromeCurve);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _entrance, curve: const Interval(0.15, 1.0));

  @override
  void didUpdateWidget(ExpandedChrome old) {
    super.didUpdateWidget(old);
    if (widget.hasTrack && !old.hasTrack) {
      _entrance.forward();
    } else if (!widget.hasTrack && old.hasTrack) {
      _entrance.reverse();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Widget _dockPill() => GlassSurface(
        radius: kDockHeight / 2,
        // Swipe down on the dock pill → collapsed chrome.
        child: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 250) widget.onCollapse();
          },
          child: SizedBox(
            height: kDockHeight,
            // Wider inner padding so even the end slots' selection capsule stays
            // inside the pill's straight middle, never poking into the rounded
            // cap (where the ClipRRect would shave it).
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DockRow(
                dock: widget.dock,
                selectedIndex: widget.onUserPage
                    ? -1
                    : widget.dock.indexWhere((s) => s.id == widget.currentId),
                onTap: (s) => widget.onOpen(s.id),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    const gap = 8.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        // The mini-player's FINAL (fully-open) width — the pill lays out once at
        // this size and the growing clip reveals it, so its contents never
        // re-flow mid-animation.
        final endInner = (w - kYouShrunk - gap) - gap;
        final endMini = endInner * kMiniFraction;

        return AnimatedBuilder(
          animation: _entrance,
          builder: (context, _) {
            final t = _t.value; // eased 0 → 1
            final you = lerpDouble(kYouExpanded, kYouShrunk, t)!;
            final miniGap = gap * t;
            final inner = (w - you - gap) - miniGap; // dock + mini share this
            final mini = inner * (kMiniFraction * t);
            final dock = inner - mini;

            return SizedBox(
              height: kDockHeight,
              child: Row(
                children: [
                  SizedBox(width: dock, height: kDockHeight, child: _dockPill()),
                  SizedBox(width: miniGap),
                  // The mini slot: a clip that widens 0 → endMini, revealing a
                  // pill laid out once at its final width.
                  SizedBox(
                    width: mini,
                    height: kDockHeight,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: endMini,
                        maxWidth: endMini,
                        child: Opacity(
                          opacity: _fade.value.clamp(0.0, 1.0),
                          child: const Center(
                            child: GlassSurface(
                              radius: kMiniPlayerHeight / 2,
                              child: MiniPlayerPill(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: gap),
                  YouCircle(
                    size: you,
                    selected: widget.onUserPage,
                    onTap: () => widget.onOpen('user'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
