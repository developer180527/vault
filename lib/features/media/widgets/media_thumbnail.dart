import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../data/local_media_library.dart';

/// A single grid tile. Uses photo_manager's own [AssetEntityImageProvider],
/// which caches thumbnails at both the native (PHCachingImageManager /
/// MediaStore) and Flutter [ImageCache] layers — the key to smooth,
/// non-flickering scrolling of a large library. A duration badge overlays
/// videos.
class MediaThumbnail extends StatelessWidget {
  const MediaThumbnail({super.key, required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: scheme.surfaceContainerHighest),
          Image(
            image: AssetEntityImageProvider(
              item.asset,
              isOriginal: false,
              thumbnailSize: const ThumbnailSize.square(300),
            ),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            errorBuilder: (context, _, _) => const SizedBox.shrink(),
          ),
          if (item.kind == MediaKind.video)
            Positioned(
              right: 4,
              bottom: 4,
              child: _DurationBadge(duration: item.duration),
            ),
        ],
      ),
    );
  }
}

class _DurationBadge extends StatelessWidget {
  const _DurationBadge({this.duration});

  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final d = duration ?? Duration.zero;
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.play_arrow, color: Colors.white, size: 12),
          const SizedBox(width: 2),
          Text('$m:$s',
              style: const TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
    );
  }
}
