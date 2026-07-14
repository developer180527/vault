import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'music_metadata.dart';

/// Dominant color of an image, for tinting the player background from album
/// art. Decodes a 24×24 preview and picks the most *saturated-weighted*
/// color bucket — a plain average washes out to gray on busy covers.
Future<Color?> dominantColorOf(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes,
        targetWidth: 24, targetHeight: 24);
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    frame.image.dispose();
    if (data == null) return null;

    // Quantize to 512 buckets (3 bits/channel); accumulate saturation-
    // weighted sums so vivid colors beat large gray areas.
    final sums = <int, List<double>>{};
    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      final r = data.getUint8(i);
      final g = data.getUint8(i + 1);
      final b = data.getUint8(i + 2);
      if (data.getUint8(i + 3) < 128) continue; // skip transparent
      final maxC = [r, g, b].reduce((a, c) => a > c ? a : c);
      final minC = [r, g, b].reduce((a, c) => a < c ? a : c);
      final saturation = maxC == 0 ? 0.0 : (maxC - minC) / maxC;
      final weight = saturation + 0.05;
      final key = (r >> 5 << 6) | (g >> 5 << 3) | (b >> 5);
      final s = sums.putIfAbsent(key, () => [0, 0, 0, 0]);
      s[0] += r * weight;
      s[1] += g * weight;
      s[2] += b * weight;
      s[3] += weight;
    }
    if (sums.isEmpty) return null;
    final top = sums.values.reduce((a, b) => a[3] > b[3] ? a : b);
    return Color.fromARGB(
        255, top[0] ~/ top[3], top[1] ~/ top[3], top[2] ~/ top[3]);
  } catch (_) {
    return null; // corrupt/unsupported image → caller uses the theme color
  }
}

/// Dominant art color per track path, cached by family arg. Null when the
/// track has no art (player falls back to the theme gradient).
final trackArtColorProvider =
    FutureProvider.family<Color?, String>((ref, path) async {
  final art = (await ref.watch(musicMetadataProvider.future))[path]?.art;
  if (art == null) return null;
  return dominantColorOf(art);
});
