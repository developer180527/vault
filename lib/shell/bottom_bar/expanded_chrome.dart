import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/debug/chrome_tuning.dart';
import '../../core/platform/design/glass_surface.dart';
import '../../core/services/service_registry.dart';
import 'dock_row.dart';
import 'mini_player_pill.dart';
import 'you_circle.dart';

/// The expanded chrome: the mini-player on its OWN row, above a full-width
/// dock and the detached You circle.
///
///     ┌───────────────────────────────┐
///     │  mini-player (full width)     │   ← only while something plays
///     ├───────────────────────────────┤
///     │  dock pill            ( You ) │
///     └───────────────────────────────┘
///
/// It used to squeeze the pill in BESIDE the dock on one row — the dock
/// compressed, its labels dropped to icon-only, and the You circle shrank, all
/// to free horizontal space. That left four elements fighting over one row and
/// read as cramped. Sharing a single row is the COLLAPSED chrome's job (see
/// [CollapsedChrome]); expanded, each gets its own.
///
/// The entrance is therefore a height change, not a width squeeze: the
/// mini-player's row grows from nothing and fades in, and the dock below never
/// moves or resizes. Dock labels stay visible, since nothing is competing for
/// the width any more.
class ExpandedChrome extends ConsumerStatefulWidget {
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
  ConsumerState<ExpandedChrome> createState() => _ExpandedChromeState();
}

class _ExpandedChromeState extends ConsumerState<ExpandedChrome>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: ref.read(chromeTuningProvider).anim,
    value: widget.hasTrack ? 1 : 0, // already playing on mount → no entrance
  );

  // Rebuilt only when the curve or fade start actually changes (both are
  // live-tunable); otherwise reused every frame.
  late Animation<double> _t;
  late Animation<double> _fade;
  ChromeTuning? _curves;

  void _syncCurves(ChromeTuning t) {
    if (_curves != null &&
        _curves!.curve == t.curve &&
        _curves!.fadeStart == t.fadeStart) {
      return;
    }
    _curves = t;
    _entrance.duration = t.anim;
    _t = CurvedAnimation(parent: _entrance, curve: t.flutterCurve);
    _fade =
        CurvedAnimation(parent: _entrance, curve: Interval(t.fadeStart, 1.0));
  }

  @override
  void didUpdateWidget(covariant ExpandedChrome old) {
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

  Widget _dockPill(ChromeTuning tune) => GlassSurface(
        radius: tune.dockHeight / 2,
        // Swipe down on the dock pill → collapsed chrome.
        child: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 250) widget.onCollapse();
          },
          child: SizedBox(
            height: tune.dockHeight,
            // Wider inner padding so even the end slots' selection capsule
            // stays inside the pill's straight middle, never poking into the
            // rounded cap (where the ClipRRect would shave it).
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DockRow(
                dock: widget.dock,
                selectedIndex: widget.onUserPage
                    ? -1
                    : widget.dock.indexWhere((s) => s.id == widget.currentId),
                onTap: (s) => widget.onOpen(s.id),
                // Full width now, so labels always have room.
                labelOpacity: 1,
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tune = ref.watch(chromeTuningProvider);
    _syncCurves(tune);

    return AnimatedBuilder(
      animation: _entrance,
      builder: (context, _) {
        final t = _t.value; // eased 0 → 1

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ---- mini-player row: grows in height, full width ----
            // Laid out once at its final height inside a clip that opens, so
            // its contents never re-flow mid-animation.
            SizedBox(
              height: tune.miniHeight * t,
              width: double.infinity,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.bottomCenter,
                  minHeight: tune.miniHeight,
                  maxHeight: tune.miniHeight,
                  child: Opacity(
                    opacity: _fade.value.clamp(0.0, 1.0),
                    child: GlassSurface(
                      radius: tune.miniHeight / 2,
                      child: const MiniPlayerPill(),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: tune.gap * t),

            // ---- dock row: fixed, never squeezed ----
            SizedBox(
              height: tune.dockHeight,
              child: Row(
                children: [
                  Expanded(child: _dockPill(tune)),
                  SizedBox(width: tune.gap),
                  YouCircle(
                    size: tune.youExpanded,
                    selected: widget.onUserPage,
                    onTap: () => widget.onOpen('user'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
