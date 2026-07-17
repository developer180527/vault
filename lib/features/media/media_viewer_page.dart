import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../core/platform/design/adaptive_icons.dart';
import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import 'data/local_media_library.dart';
import 'data/media_providers.dart';
import 'data/media_trash.dart';
import 'widgets/video_surface.dart';
import 'widgets/viewer_top_bar.dart';

/// Media viewer: swipe between items, pinch-zoom / double-tap photos, and
/// play videos inline. The media renders in a CONTAINED area between the top
/// bar and the bottom action bar (back/share/edit/crop/delete), like a
/// regular media viewer — not edge-to-edge behind overlaid chrome. Uses
/// PhotoViewGallery so zoom and page-swipe coexist cleanly (a plain
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
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Native share sheet for the current item — works everywhere share_plus
  /// does (iOS/Android sheets, macOS popover, Windows dialog).
  Future<void> _share() async {
    final item = widget.items[_index];
    // Origin file: full quality, correct filename/UTI for the receiving app.
    final file = await item.asset.originFile;
    if (file == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This item isn’t available to share.')),
        );
      }
      return;
    }
    if (!mounted) return;
    // iPad requires an anchor rect for the share popover.
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  /// Move the current item to Vault's trash (30-day recently-deleted) after a
  /// confirmation — the grid behind drops it once trashed.
  Future<void> _delete() async {
    final item = widget.items[_index];
    final isVideo = item.kind == MediaKind.video;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete this ${isVideo ? 'video' : 'photo'}?'),
        content: const Text(
          'It moves to Recently Deleted and is permanently removed after '
          '30 days.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return; // ref is unusable after unmount (throws)
    await ref.read(mediaTrashProvider.notifier).trash(item.id);
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.read(localMediaLibraryProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      // Standardized fullscreen-media chrome; the media is contained between
      // the top bar and the action bar rather than rendered behind them.
      appBar: ViewerTopBar(title: '${_index + 1} of ${widget.items.length}'),
      bottomNavigationBar: _ViewerActionBar(onShare: _share, onDelete: _delete),
      // The video controls float in this body Stack, ABOVE the gallery, so
      // they span the whole body — inside PhotoViewGallery a video is sized to
      // its letterbox strip, which would crush the controls onto the picture.
      body: Stack(
        children: [
          Positioned.fill(
            child: PhotoViewGallery.builder(
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
                    // Videos don't pinch-zoom; keep them fixed and let the
                    // player handle its gestures. No hero: flying a live video
                    // player duplicates its controller (echo) and breaks
                    // teardown. Controls are floated separately (below), so the
                    // page renders picture-only.
                    disableGestures: true,
                    child: _VideoPage(
                      item: item,
                      library: library,
                      active: i == _index,
                    ),
                  );
                }
                return PhotoViewGalleryPageOptions.customChild(
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 4,
                  child: _PhotoContent(item: item, library: library),
                );
              },
            ),
          ),
          // Full-body transport overlay for the active video only. Reads the
          // single video session from the central controller, so it always
          // targets whatever is actually playing.
          if (widget.items[_index].kind == MediaKind.video)
            Positioned.fill(
              child: _VideoControlsOverlay(item: widget.items[_index]),
            ),
        ],
      ),
    );
  }
}

/// Bottom action bar: the standard media-viewer tools. Share and Delete are
/// live (native share sheet; Vault trash). Edit/crop stay placeholders until
/// the editing pipeline exists.
class _ViewerActionBar extends StatelessWidget {
  const _ViewerActionBar({required this.onShare, required this.onDelete});

  final VoidCallback onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    void comingSoon(String what) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what — coming with the media editing tools')),
    );

    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                tooltip: 'Share',
                color: Colors.white,
                icon: const AdaptiveIcon(VaultIcons.share, size: 22),
                onPressed: onShare,
              ),
              IconButton(
                tooltip: 'Edit',
                color: Colors.white,
                icon: const AdaptiveIcon(VaultIcons.edit, size: 22),
                onPressed: () => comingSoon('Edit'),
              ),
              IconButton(
                tooltip: 'Crop',
                color: Colors.white,
                icon: const AdaptiveIcon(VaultIcons.crop, size: 22),
                onPressed: () => comingSoon('Crop'),
              ),
              IconButton(
                tooltip: 'Delete',
                color: Colors.white,
                icon: const AdaptiveIcon(VaultIcons.trash, size: 22),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
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
  late final Future<Uint8List?> _thumb = widget.library.thumbnail(
    widget.item,
    size: 600,
  );

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

/// A video page in the gallery, playing through the CENTRAL
/// [PlaybackController] — no widget owns a player anymore. Only the ACTIVE
/// page holds the (single) video session: becoming active opens it (resuming
/// from the saved position), becoming inactive or leaving the tree closes it.
/// `closeVideo(onlyIf:)` guards the handoff when swiping video→video, since
/// the newer page's `openVideo` already superseded the session.
class _VideoPage extends ConsumerStatefulWidget {
  const _VideoPage({
    required this.item,
    required this.library,
    required this.active,
  });

  final MediaItem item;
  final LocalMediaLibrary library;
  final bool active;

  @override
  ConsumerState<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<_VideoPage> {
  // Captured once: `ref` is unusable in dispose() (throws and aborts teardown
  // — the root cause of the old audio-persistence bug).
  late final PlaybackController _playback = ref.read(playbackProvider.notifier);

  VideoPlayerController? _videoController;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _open();
  }

  @override
  void didUpdateWidget(_VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _open();
    } else if (!widget.active && oldWidget.active) {
      _close();
      setState(() => _videoController = null);
    }
  }

  Future<void> _open() async {
    try {
      final path = await widget.library.videoPath(widget.item);
      if (!mounted || !widget.active) return;
      if (path == null) {
        setState(() => _failed = true);
        return;
      }
      final controller = await _playback.openVideo(
        Playable(
          id: widget.item.id,
          kind: PlayableKind.video,
          // Usually a local file; http covers streamed sources (e.g. an
          // iCloud-offloaded asset materialized as a URL).
          uri: path.startsWith('http') ? Uri.parse(path) : Uri.file(path),
          title: widget.item.asset.title ?? 'Video',
        ),
      );
      if (!mounted) return; // session stays; dispose() will close it
      setState(() => _videoController = controller);
    } catch (e) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _close() => _playback.closeVideo(onlyIf: widget.item.id);

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Center(
        child: Text(
          'Video unavailable',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    final controller = _videoController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // Picture only — the transport chrome is floated at the Scaffold level so
    // it spans the whole body rather than this letterboxed page.
    return VideoSurface(
      controller: controller,
      title: widget.item.asset.title,
      showControls: false,
    );
  }
}

/// Floats [VideoControls] over the whole viewer body for the active video.
/// Watches the central playback session so the overlay appears exactly when a
/// controller is live for [item] and vanishes when it isn't.
class _VideoControlsOverlay extends ConsumerWidget {
  const _VideoControlsOverlay({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(playbackProvider).video;
    final controller = ref.read(playbackProvider.notifier).videoController;
    if (session?.id != item.id || controller == null) {
      return const SizedBox.shrink();
    }
    return VideoControls(controller: controller, title: item.asset.title);
  }
}
