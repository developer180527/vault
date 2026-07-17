import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart' show MethodCall;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import 'data/local_media_library.dart';
import 'data/media_providers.dart';
import 'data/media_trash.dart';
import 'media_viewer_page.dart';
import 'widgets/media_thumbnail.dart';

/// The Media tab: on-device photos/videos (gated behind a real OS permission),
/// narrowed with the filter dropdown in the tab's status bar. Music lives in
/// its own top-level service tab.
class MediaLibraryPage extends ConsumerWidget {
  const MediaLibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(mediaAccessProvider);

    return access.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) =>
          const _MediaMessage(icon: Icons.error_outline, title: 'Media error'),
      data: (state) => switch (state) {
        MediaAccess.authorized || MediaAccess.limited => _MediaGrid(
          limited: state == MediaAccess.limited,
        ),
        MediaAccess.denied => const _PermissionDenied(),
        MediaAccess.unavailable => const _MediaMessage(
          icon: Icons.devices_other,
          title: 'Local media isn’t available here',
          subtitle:
              'Open Vault on your phone, tablet, or Mac to browse photos '
              'and videos on this device.',
        ),
      },
    );
  }
}

class _MediaGrid extends ConsumerStatefulWidget {
  const _MediaGrid({required this.limited});

  final bool limited;

  @override
  ConsumerState<_MediaGrid> createState() => _MediaGridState();
}

class _MediaGridState extends ConsumerState<_MediaGrid>
    with WidgetsBindingObserver {
  /// Accumulated pinch scale since the last tier step (rebased on each step so
  /// one continuous pinch can cross several tiers, Apple Photos-style).
  double _pinchBase = 1.0;

  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    // Keep the grid live with the OS library: a new screenshot, camera shot,
    // or import should appear without a manual reload. The change-notify
    // callback covers in-session edits; the lifecycle observer catches
    // anything that happened while Vault was backgrounded.
    WidgetsBinding.instance.addObserver(this);
    PhotoManager.addChangeCallback(_onLibraryChanged);
    PhotoManager.startChangeNotify();
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    PhotoManager.removeChangeCallback(_onLibraryChanged);
    PhotoManager.stopChangeNotify();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  // The OS fires change notifications in bursts (a single save can emit
  // several) — coalesce so we rebuild the grid once.
  void _onLibraryChanged(MethodCall _) {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 400), _refresh);
  }

  void _refresh() {
    if (mounted) ref.invalidate(mediaItemsProvider);
  }

  void _onScaleStart(ScaleStartDetails d) => _pinchBase = 1.0;

  void _onScaleUpdate(ScaleUpdateDetails d) {
    // Two fingers only — single-finger "scale" events are just scrolling.
    if (d.pointerCount < 2) return;
    final relative = d.scale / _pinchBase;
    if (relative > 1.3) {
      ref.read(mediaZoomProvider.notifier).zoomIn(); // spread → bigger tiles
      _pinchBase = d.scale;
    } else if (relative < 1 / 1.3) {
      ref.read(mediaZoomProvider.notifier).zoomOut(); // pinch → more tiles
      _pinchBase = d.scale;
    }
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(mediaItemsProvider);
    final tileExtent = mediaZoomTiers[ref.watch(mediaZoomProvider)];
    // Vault-trashed items disappear from the library instantly (the asset
    // still exists in the OS until the trash purges it).
    final trashedIds = ref.watch(trashedIdsProvider);

    return Stack(
      children: [
        Positioned.fill(
          child: itemsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _MediaMessage(
              icon: Icons.error_outline,
              title: 'Could not load media: $e',
            ),
            data: (allItems) {
              final items = trashedIds.isEmpty
                  ? allItems
                  : [
                      for (final it in allItems)
                        if (!trashedIds.contains(it.id)) it,
                    ];
              return items.isEmpty
                  ? const _MediaMessage(
                      icon: Icons.photo_library_outlined,
                      title: 'Nothing here yet',
                      subtitle: 'No items match this filter.',
                    )
                  // Pinch in/out steps the zoom tier. The scale recognizer only
                  // acts on 2-pointer gestures, so one-finger scrolling passes
                  // straight through to the grid untouched.
                  : GestureDetector(
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      child: GridView.builder(
                        // Apple Photos orientation: the library OPENS at the
                        // newest items (bottom) and scrolling UP walks into the
                        // past. Items arrive newest-first, so reversing the
                        // scroll puts index 0 at the bottom with zero offset —
                        // no scroll-to-end jump on load.
                        reverse: true,
                        // The shell's toolbar and dock are translucent layers
                        // the grid scrolls beneath — inset the content, not the
                        // viewport.
                        padding: EdgeInsets.fromLTRB(
                          2,
                          2 + MediaQuery.paddingOf(context).top,
                          2,
                          2 + MediaQuery.paddingOf(context).bottom,
                        ),
                        // Decode two viewports of tiles ahead of the scroll so
                        // thumbnails are generated and cached before they enter
                        // view — the main lever against load-lag while
                        // scrolling.
                        scrollCacheExtent: ScrollCacheExtent.viewport(2.0),
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: tileExtent,
                          // Hairline gaps, Apple Photos-style: the pictures ARE
                          // the interface; chrome between them is noise.
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                        ),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          // Infinite scroll: approaching the tail requests the
                          // next page (post-frame — provider mutation is
                          // illegal during build). Re-entrancy is guarded in
                          // the notifier.
                          if (i >= items.length - 40) {
                            Future.microtask(
                              () => ref
                                  .read(mediaItemsProvider.notifier)
                                  .loadMore(),
                            );
                          }
                          return GestureDetector(
                            // Stable key keeps element/image identity across
                            // rebuilds so cached thumbnails aren't dropped and
                            // reloaded. No Hero: per-cell heroes cause flicker.
                            key: ValueKey(items[i].id),
                            // Root navigator so the viewer covers the whole
                            // shell (app bar + bottom nav), not just the tab's
                            // body.
                            onTap: () => Navigator.of(
                              context,
                              rootNavigator: true,
                            ).push(_viewerRoute(items, i)),
                            child: MediaThumbnail(item: items[i]),
                          );
                        },
                      ),
                    );
            },
          ),
        ),
        if (widget.limited)
          Positioned(
            top: 8 + MediaQuery.paddingOf(context).top,
            left: 12,
            right: 12,
            child: _LimitedBanner(
              onManage: () =>
                  ref.read(localMediaLibraryProvider).presentLimitedPicker(),
            ),
          ),
      ],
    );
  }
}

/// Fade transition into the fullscreen viewer (replaces the hero transition,
/// which is unsafe for live video players).
Route<void> _viewerRoute(List<MediaItem> items, int index) {
  return PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) =>
        MediaViewerPage(items: items, initialIndex: index),
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _LimitedBanner extends StatelessWidget {
  const _LimitedBanner({required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text("You've shared only some photos with Vault."),
            ),
            TextButton(onPressed: onManage, child: const Text('Select more')),
          ],
        ),
      ),
    );
  }
}

class _PermissionDenied extends ConsumerWidget {
  const _PermissionDenied();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Vault needs access to your photos',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Allow photo & video access to browse and back up your library.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: () =>
                      ref.read(mediaAccessProvider.notifier).refresh(),
                  child: const Text('Try again'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      ref.read(localMediaLibraryProvider).openSettings(),
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaMessage extends StatelessWidget {
  const _MediaMessage({required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
