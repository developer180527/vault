import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/content_cache.dart';
import '../../core/client/vault_client.dart';
import '../../core/models/server_photo.dart';
import '../../core/playback/playable.dart';
import '../media/video_playback_page.dart';

/// The full backed-up library, every page fetched (726 items = 2 requests;
/// the grid itself stays lazy). Newest capture first, as the server orders.
final photoTimelineProvider = FutureProvider<List<ServerPhoto>>((ref) async {
  final photos = ref.watch(vaultClientProvider).photos;
  final all = <ServerPhoto>[];
  for (var offset = 0;; offset += 500) {
    final page = await photos.list(limit: 500, offset: offset);
    all.addAll(page.photos);
    if (page.photos.length < 500) break;
  }
  return all;
});

/// Thumbnail bytes through the content cache (memory → disk → network with
/// ETag revalidation) — scrolling a month you've seen paints instantly.
/// autoDispose: scrolled-past cells must not pin bytes in provider state.
final photoThumbProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, id) async {
  final api = ref.watch(vaultClientProvider).photos;
  final cache = ref.watch(contentCacheProvider);
  return cache.image(api.thumbUri(id), headers: await api.authHeaders());
});

/// Full-resolution original, same cache path (photos only — videos stream).
final photoFullProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, id) async {
  final api = ref.watch(vaultClientProvider).photos;
  final cache = ref.watch(contentCacheProvider);
  return cache.image(api.contentUri(id), headers: await api.authHeaders());
});

/// Opens the timeline over the whole shell.
void openPhotoTimeline(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const PhotoTimelinePage()),
  );
}

/// One flattened timeline row model: a month header or a grid slice.
sealed class _Section {
  const _Section();
}

class _MonthHeader extends _Section {
  const _MonthHeader(this.label);
  final String label;
}

class _MonthGrid extends _Section {
  const _MonthGrid(this.items, this.baseIndex);
  final List<ServerPhoto> items;

  /// Index of items.first within the flat timeline (viewer paging).
  final int baseIndex;
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
];

List<_Section> _sectionize(List<ServerPhoto> all) {
  final sections = <_Section>[];
  var i = 0;
  while (i < all.length) {
    final d = all[i].when;
    final label = '${_monthNames[d.month - 1]} ${d.year}';
    final start = i;
    while (i < all.length &&
        all[i].when.year == d.year &&
        all[i].when.month == d.month) {
      i++;
    }
    sections
      ..add(_MonthHeader(label))
      ..add(_MonthGrid(all.sublist(start, i), start));
  }
  return sections;
}

/// Month-sectioned grid of everything backed up. Tap a cell → the viewer.
class PhotoTimelinePage extends ConsumerWidget {
  const PhotoTimelinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(photoTimelineProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Library unavailable: $e')),
        data: (all) {
          if (all.isEmpty) {
            return const Center(
              child: Text('Nothing backed up yet.'),
            );
          }
          final sections = _sectionize(all);
          return RefreshIndicator(
            onRefresh: () => ref.refresh(photoTimelineProvider.future),
            child: CustomScrollView(
              slivers: [
                for (final s in sections)
                  switch (s) {
                    _MonthHeader(:final label) => SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
                          child: Text(
                            label,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ),
                    _MonthGrid(:final items, :final baseIndex) =>
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 110,
                            mainAxisSpacing: 2,
                            crossAxisSpacing: 2,
                          ),
                          itemCount: items.length,
                          itemBuilder: (context, i) => _Cell(
                            photo: items[i],
                            onTap: () => _openViewer(
                                context, all, baseIndex + i),
                          ),
                        ),
                      ),
                  },
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openViewer(BuildContext context, List<ServerPhoto> all, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ViewerPage(items: all, initialIndex: index),
      ),
    );
  }
}

class _Cell extends ConsumerWidget {
  const _Cell({required this.photo, required this.onTap});

  final ServerPhoto photo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = photo.hasThumb
        ? ref.watch(photoThumbProvider(photo.id)).asData?.value
        : null;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bytes != null)
            Image.memory(bytes,
                fit: BoxFit.cover, cacheWidth: 220, gaplessPlayback: true)
          else
            ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Icon(
                photo.kind == 'video'
                    ? Icons.videocam_outlined
                    : Icons.photo_outlined,
                size: 22,
                color: scheme.onSurfaceVariant,
              ),
            ),
          if (photo.kind == 'video')
            const Positioned(
              right: 4,
              bottom: 4,
              child: Icon(Icons.play_circle_fill,
                  size: 18, color: Colors.white),
            ),
        ],
      ),
    );
  }
}

/// Swipeable full-screen viewer. Photos render full-res (pinch-zoom via
/// InteractiveViewer); videos hand off to the central playback session.
class _ViewerPage extends ConsumerStatefulWidget {
  const _ViewerPage({required this.items, required this.initialIndex});

  final List<ServerPhoto> items;
  final int initialIndex;

  @override
  ConsumerState<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends ConsumerState<_ViewerPage> {
  late final PageController _pager =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _playVideo(ServerPhoto p) async {
    final api = ref.read(vaultClientProvider).photos;
    final headers = await api.authHeaders();
    if (!mounted) return;
    await openVideoPlayback(
      context,
      Playable(
        id: p.id,
        kind: PlayableKind.video,
        uri: api.contentUri(p.id),
        title: p.name,
        headers: headers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.items[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(current.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15)),
      ),
      body: PageView.builder(
        controller: _pager,
        onPageChanged: (i) => setState(() => _index = i),
        itemCount: widget.items.length,
        itemBuilder: (context, i) {
          final p = widget.items[i];
          if (p.kind == 'video') {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Thumb(photo: p, size: 280),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play video'),
                    onPressed: () => _playVideo(p),
                  ),
                ],
              ),
            );
          }
          return _FullPhoto(photo: p);
        },
      ),
    );
  }
}

class _Thumb extends ConsumerWidget {
  const _Thumb({required this.photo, required this.size});
  final ServerPhoto photo;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = photo.hasThumb
        ? ref.watch(photoThumbProvider(photo.id)).asData?.value
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size * 0.75,
        child: bytes != null
            ? Image.memory(bytes, fit: BoxFit.cover)
            : const ColoredBox(
                color: Colors.white10,
                child:
                    Icon(Icons.videocam_outlined, color: Colors.white54)),
      ),
    );
  }
}

class _FullPhoto extends ConsumerWidget {
  const _FullPhoto({required this.photo});
  final ServerPhoto photo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final full = ref.watch(photoFullProvider(photo.id)).asData?.value;
    // Thumb as the instant placeholder while the original streams in.
    final thumb = photo.hasThumb
        ? ref.watch(photoThumbProvider(photo.id)).asData?.value
        : null;
    final bytes = full ?? thumb;
    if (bytes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return InteractiveViewer(
      maxScale: 6,
      child: Center(
        child: Image.memory(bytes, fit: BoxFit.contain,
            gaplessPlayback: true),
      ),
    );
  }
}
