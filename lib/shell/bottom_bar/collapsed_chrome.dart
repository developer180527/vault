import 'package:flutter/material.dart';

import '../../core/platform/design/glass_surface.dart';
import 'metrics.dart';
import 'mini_player_pill.dart';
import 'you_circle.dart';

/// The tucked-away chrome, one row: a 4-box button (tap → expand), the mini
/// player stretched between (when a track is loaded), and the You circle.
class CollapsedChrome extends StatelessWidget {
  const CollapsedChrome({
    super.key,
    required this.hasTrack,
    required this.onUserPage,
    required this.onExpand,
    required this.onYou,
  });

  final bool hasTrack;
  final bool onUserPage;
  final VoidCallback onExpand;
  final VoidCallback onYou;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Collapsed, everything shrinks to the mini-player's height so the 4-box,
    // the pill, and the You circle read as one consistent 44pt row.
    const h = kMiniPlayerHeight;
    return SizedBox(
      height: h,
      child: Row(
        children: [
          // The 4-box: tap to bring the full dock back.
          GlassSurface(
            radius: h / 2,
            child: Semantics(
              button: true,
              label: 'Show navigation',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onExpand,
                child: SizedBox(
                  width: h,
                  height: h,
                  child: Icon(
                    Icons.grid_view_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: hasTrack
                ? GlassSurface(radius: h / 2, child: const MiniPlayerPill())
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 8),
          YouCircle(selected: onUserPage, onTap: onYou, size: h),
        ],
      ),
    );
  }
}
