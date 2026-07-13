import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/local_media_library.dart';
import 'data/media_providers.dart';
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
        MediaAccess.authorized ||
        MediaAccess.limited =>
          _MediaGrid(limited: state == MediaAccess.limited),
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

class _MediaGrid extends ConsumerWidget {
  const _MediaGrid({required this.limited});

  final bool limited;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(mediaItemsProvider);

    return Stack(
      children: [
        Positioned.fill(
          child: itemsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _MediaMessage(
                icon: Icons.error_outline, title: 'Could not load media: $e'),
            data: (items) => items.isEmpty
                ? const _MediaMessage(
                    icon: Icons.photo_library_outlined,
                    title: 'Nothing here yet',
                    subtitle: 'No items match this filter.')
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    // Decode two viewports of tiles ahead of the scroll so
                    // thumbnails are generated and cached before they enter
                    // view — the main lever against load-lag while scrolling.
                    scrollCacheExtent: ScrollCacheExtent.viewport(2.0),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 160,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, i) => GestureDetector(
                      // Stable key keeps element/image identity across rebuilds
                      // so cached thumbnails aren't dropped and reloaded. No
                      // Hero here: per-cell heroes cause scroll flicker.
                      key: ValueKey(items[i].id),
                      // Root navigator so the viewer covers the whole shell
                      // (app bar + bottom nav), not just the tab's body.
                      onTap: () => Navigator.of(context, rootNavigator: true)
                          .push(_viewerRoute(items, i)),
                      child: MediaThumbnail(item: items[i]),
                    ),
                  ),
          ),
        ),
        if (limited)
          Positioned(
            top: 8,
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
                child: Text("You've shared only some photos with Vault.")),
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
            Icon(Icons.photo_library_outlined,
                size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text('Vault needs access to your photos',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Allow photo & video access to browse and back up your library.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
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
  const _MediaMessage(
      {required this.icon, required this.title, this.subtitle});

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
            Text(title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ],
        ),
      ),
    );
  }
}
