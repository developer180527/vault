import 'package:flutter/material.dart';

import '../../core/platform/design/adaptive_icons.dart';
import '../../core/platform/design/glass_surface.dart';
import 'metrics.dart';

/// The detached You circle, Apple Music-style — shared by both chrome states.
/// [size] shrinks it (in the collapsed row, or when the mini-player squeezes in
/// beside it). Always the person glyph, never the profile picture — the avatar
/// lives on the You page; the dock stays a clean, consistent tab symbol.
class YouCircle extends StatelessWidget {
  const YouCircle({
    super.key,
    required this.selected,
    required this.onTap,
    this.size = kDockHeight,
  });

  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassSurface(
      radius: size / 2,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: CircleAvatar(
              radius: size * 0.27,
              backgroundColor: selected
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              child: AdaptiveIcon(
                VaultIcons.user,
                selected: selected,
                size: size * 0.31,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
