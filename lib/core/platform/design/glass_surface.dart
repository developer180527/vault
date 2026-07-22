import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// A Flutter-drawn glassmorphic surface: a rounded rect with a backdrop blur,
/// a translucent theme-aware fill (subtle top→bottom gradient), and a hairline
/// specular edge. Unlike a native platform-view glass, this is ordinary Flutter
/// paint — so it can be freely scaled, faded, and size-animated, which is what
/// lets the bottom chrome animate the mini-player smoothly.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.radius,
    required this.child,
    this.blur = 24,
  });

  final double radius;
  final Widget child;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final br = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: br,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                scheme.surface.withValues(alpha: dark ? 0.55 : 0.74),
                scheme.surface.withValues(alpha: dark ? 0.40 : 0.60),
              ],
            ),
            border: Border.all(
              color: scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.10),
              width: 0.6,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
