import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../logging/vault_log.dart';

final _log = VaultLog.tag('sfsymbols');

const _channel = MethodChannel('vault/sf-symbols');

/// PNG bytes per (name, pixel size). Symbols are tiny (<2KB) and the app uses
/// a few dozen, so an unbounded session cache is fine.
final _cache = <String, Future<Uint8List?>>{};

Future<Uint8List?> _render(String name, double size, double scale) {
  final key = '$name@${(size * scale).round()}';
  return _cache.putIfAbsent(key, () async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('render', {
        'name': name,
        'size': size,
        'scale': scale,
      });
      return bytes;
    } catch (e) {
      // Unknown symbol name or channel missing (e.g. older OS): the widget
      // falls back to the Material glyph. Logged once thanks to the cache.
      _log.warn('SF Symbol unavailable, using fallback',
          fields: {'name': name, 'error': '$e'});
      return null;
    }
  });
}

/// A real SF Symbol, rendered by the OS (UIImage/NSImage systemName APIs)
/// as a white template bitmap and tinted in Flutter. Falls back to
/// [fallback] (the Material glyph) while loading or when the symbol/channel
/// is unavailable, so the widget is safe on any platform.
class SfSymbolIcon extends StatelessWidget {
  const SfSymbolIcon(
    this.name, {
    super.key,
    required this.fallback,
    this.size,
    this.color,
  });

  /// SF Symbol name, e.g. 'gearshape', 'text.document', 'play.rectangle'.
  final String name;

  /// Material glyph used while loading / when the symbol can't be rendered.
  final IconData fallback;

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24;
    final resolvedColor = color ?? iconTheme.color;
    final scale = MediaQuery.devicePixelRatioOf(context);

    return FutureBuilder<Uint8List?>(
      future: _render(name, resolvedSize, scale),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return Icon(fallback, size: resolvedSize, color: resolvedColor);
        }
        // Symbols aren't square; constrain by height and keep aspect. The
        // white template is tinted via srcIn like Icon's own glyph color.
        return SizedBox(
          width: resolvedSize * 1.3,
          height: resolvedSize,
          child: Image.memory(
            bytes,
            scale: scale,
            color: resolvedColor,
            colorBlendMode: BlendMode.srcIn,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }
}
