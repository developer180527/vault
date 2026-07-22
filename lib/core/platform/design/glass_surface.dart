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
    this.blur = 32,
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
        // Heavier blur reads as thicker glass, and desaturates less of the
        // scene so it stays see-through rather than a flat tint.
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          // Low-opacity tint (you can see the content behind), brighter at the
          // top like light pooling on the glass, fading toward the bottom; plus
          // a bright hairline border that reads as the glass's specular rim.
          decoration: BoxDecoration(
            borderRadius: br,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                scheme.surface.withValues(alpha: dark ? 0.42 : 0.55),
                scheme.surface.withValues(alpha: dark ? 0.24 : 0.40),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: dark ? 0.22 : 0.50),
              width: 0.8,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
