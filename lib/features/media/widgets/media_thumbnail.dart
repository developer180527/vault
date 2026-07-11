import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_media_library.dart';
import '../data/media_providers.dart';

/// A single grid tile: the asset thumbnail, with a duration badge for videos.
/// Thumbnail bytes are loaded lazily via the library port and cached in a
/// small in-memory map keyed by asset id.
class MediaThumbnail extends ConsumerStatefulWidget {
  const MediaThumbnail({super.key, required this.item});

  final MediaItem item;

  @override
  ConsumerState<MediaThumbnail> createState() => _MediaThumbnailState();
}

class _MediaThumbnailState extends ConsumerState<MediaThumbnail> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: scheme.surfaceContainerHighest),
          FutureBuilder(
            future: ref
                .read(localMediaLibraryProvider)
                .thumbnail(widget.item),
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null) return const SizedBox.shrink();
              return Image.memory(bytes, fit: BoxFit.cover);
            },
          ),
          if (widget.item.kind == MediaKind.video)
            Positioned(
              right: 4,
              bottom: 4,
              child: _DurationBadge(duration: widget.item.duration),
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
