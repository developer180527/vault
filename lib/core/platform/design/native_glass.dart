import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform_info.dart';

/// One rounded glass area inside a [NativeGlassPanel], in logical pixels
/// relative to the panel's top-left.
@immutable
class GlassRegion {
  const GlassRegion({required this.rect, required this.radius});

  final Rect rect;
  final double radius;

  Map<String, double> toMessage() => {
        'x': rect.left,
        'y': rect.top,
        'w': rect.width,
        'h': rect.height,
        'r': radius,
      };
}

/// The system material behind the bottom chrome, as ONE platform view.
///
/// On iOS this embeds a single UIKit view hosting a `UIVisualEffectView` per
/// [regions] entry (liquid glass on iOS 26+, blur before) underneath [child].
/// One platform view instead of one per surface: each embedded UIKit view
/// forces a hybrid-composition layer split per frame, and three of them
/// caused frame-scheduler contention (flicker, "reported frame time is
/// older" warnings).
///
/// On non-Apple platforms the child renders as-is — its surfaces provide
/// their own Material (see [NativeGlassSurface]).
class NativeGlassPanel extends StatelessWidget {
  const NativeGlassPanel({
    super.key,
    required this.size,
    required this.regions,
    required this.child,
  });

  final Size size;
  final List<GlassRegion> regions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isIOS) return child;
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: UiKitView(
              // Regions are baked in at creation; recreate when layout
              // changes (rotation, mini player appearing) — rare events.
              key: ValueKey(
                  'glass-${size.width}x${size.height}-${regions.length}'),
              viewType: 'vault/native-glass-panel',
              creationParams: {
                'regions': [for (final r in regions) r.toMessage()],
              },
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// A rounded surface in the platform's design language.
///
/// On iOS the actual glass material is painted by the enclosing
/// [NativeGlassPanel]; this widget only contributes the hairline edge and a
/// transparent Material so ink/text render correctly on top. Everywhere else
/// it's a self-contained elevated Material surface.
class NativeGlassSurface extends StatelessWidget {
  const NativeGlassSurface({
    super.key,
    required this.radius,
    required this.child,
  });

  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderRadius = BorderRadius.circular(radius);

    if (!isIOS) {
      return Material(
        color: scheme.surfaceContainer,
        elevation: 6,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: child,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: 0.10),
          width: 0.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}
