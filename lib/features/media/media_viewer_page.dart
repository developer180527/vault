import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import 'data/local_media_library.dart';
import 'data/media_providers.dart';
import 'widgets/vault_media_player.dart';
import 'widgets/viewer_top_bar.dart';

/// Fullscreen media viewer: swipe between items, pinch-zoom / double-tap photos,
/// and play videos inline. Opened from the Media grid with a hero transition.
/// Uses PhotoViewGallery so zoom and page-swipe coexist cleanly (a plain
/// InteractiveViewer would swallow the swipe).
class MediaViewerPage extends ConsumerStatefulWidget {
  const MediaViewerPage({
    super.key,
    required this.items,
    required this.initialIndex,
  });

  final List<MediaItem> items;
  final int initialIndex;

  @override
  ConsumerState<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends ConsumerState<MediaViewerPage> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.read(localMediaLibraryProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      // Standardized fullscreen-media chrome; editing actions land in its
      // action slot later.
      appBar: ViewerTopBar(title: '${_index + 1} of ${widget.items.length}'),
      body: PhotoViewGallery.builder(
        pageController: _controller,
        itemCount: widget.items.length,
        onPageChanged: (i) => setState(() => _index = i),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (_, _) =>
            const Center(child: CircularProgressIndicator()),
        builder: (context, i) {
          final item = widget.items[i];
          if (item.kind == MediaKind.video) {
            return PhotoViewGalleryPageOptions.customChild(
              // Videos don't pinch-zoom; keep them fixed and let the player
              // handle its own gestures. No hero: flying a live video player
              // duplicates its controller (echo) and breaks teardown.
              disableGestures: true,
              child: _VideoPage(
                  item: item, library: library, active: i == _index),
            );
          }
          return PhotoViewGalleryPageOptions.customChild(
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 4,
            child: _PhotoContent(item: item, library: library),
          );
        },
      ),
    );
  }
}

/// Full-resolution photo, with the fast thumbnail as an instant placeholder.
/// Stateful so the load futures are created ONCE — a FutureBuilder fed a
/// fresh `library.fullImage(...)` per build refetched and re-decoded the
/// full-res image on every viewer rebuild (each page swipe sets state).
class _PhotoContent extends StatefulWidget {
  const _PhotoContent({required this.item, required this.library});

  final MediaItem item;
  final LocalMediaLibrary library;

  @override
  State<_PhotoContent> createState() => _PhotoContentState();
}

class _PhotoContentState extends State<_PhotoContent> {
  late final Future<Uint8List?> _full = widget.library.fullImage(widget.item);
  late final Future<Uint8List?> _thumb =
      widget.library.thumbnail(widget.item, size: 600);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _full,
      builder: (context, snapshot) {
        if (snapshot.data case final bytes?) {
          return Image.memory(bytes, fit: BoxFit.contain);
        }
        return FutureBuilder(
          future: _thumb,
          builder: (context, thumb) => thumb.data != null
              ? Image.memory(thumb.data!, fit: BoxFit.contain)
              : const Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}

/// Resolves the video's playable path exactly once, then hands it to a single
/// [VaultMediaPlayer]. Resolving in `build` (as a fresh Future each time) churned
/// the player — recreating controllers on every rebuild, which caused the echo
/// and left audio playing after close.
class _VideoPage extends StatefulWidget {
  const _VideoPage(
      {required this.item, required this.library, required this.active});

  final MediaItem item;
  final LocalMediaLibrary library;
  final bool active;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  String? _path;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final path = await widget.library.videoPath(widget.item);
    if (mounted) {
      setState(() {
        _path = path;
        _resolved = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_resolved) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_path == null) {
      return const Center(
        child: Text('Video unavailable',
            style: TextStyle(color: Colors.white70)),
      );
    }
    // Stable key: the player's State persists across viewer rebuilds → one
    // controller, created and disposed exactly once.
    return VaultMediaPlayer(
      key: ValueKey('player-${widget.item.id}'),
      source: _path!,
      mediaId: widget.item.id,
      active: widget.active,
    );
  }
}
