import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/vault_log.dart';
import '../../../core/platform/platform_info.dart';
import 'local_media_library.dart';

final _log = VaultLog.tag('media');

/// The active library implementation for this host. Android/iOS/macOS have a
/// system photo library; web, Windows, and Linux don't.
final localMediaLibraryProvider = Provider<LocalMediaLibrary>((ref) {
  return (isAndroidOrIOS || isMacOS)
      ? const PhotoManagerLibrary()
      : const UnsupportedMediaLibrary();
});

/// Current access grant. Requesting on build shows the OS dialog the first time
/// the Media tab is opened (contextual), and returns instantly for users who
/// already granted. Failures degrade to [MediaAccess.unavailable].
class MediaAccessNotifier extends AsyncNotifier<MediaAccess> {
  @override
  Future<MediaAccess> build() async {
    final access = await ref.watch(localMediaLibraryProvider).requestAccess();
    _log.info('Media access resolved', fields: {'state': access.name});
    return access;
  }

  /// Re-request after the user changes settings, or taps "Allow".
  Future<void> refresh() async {
    state = const AsyncLoading();
    state =
        await AsyncValue.guard(ref.read(localMediaLibraryProvider).requestAccess);
  }
}

final mediaAccessProvider =
    AsyncNotifierProvider<MediaAccessNotifier, MediaAccess>(
        MediaAccessNotifier.new);

/// The floating filter pill's selection.
final mediaFilterProvider = NotifierProvider<MediaFilterNotifier, MediaFilter>(
    MediaFilterNotifier.new);

class MediaFilterNotifier extends Notifier<MediaFilter> {
  @override
  MediaFilter build() => MediaFilter.all;
  void set(MediaFilter filter) => state = filter;
}

/// Grid density tiers, Apple-Photos style: pinch out → bigger tiles (fewer
/// columns), pinch in → more thumbnails. Values are max tile extents fed to
/// the grid delegate, so every tier adapts to the window width.
const mediaZoomTiers = <double>[70.0, 105.0, 150.0, 220.0];

class MediaZoomNotifier extends Notifier<int> {
  @override
  int build() => 2; // 150pt tiles — the balanced default.

  void zoomIn() => state = (state + 1).clamp(0, mediaZoomTiers.length - 1);
  void zoomOut() => state = (state - 1).clamp(0, mediaZoomTiers.length - 1);
}

final mediaZoomProvider =
    NotifierProvider<MediaZoomNotifier, int>(MediaZoomNotifier.new);

/// The media grid contents for the current filter, loaded in pages so a large
/// library isn't capped (the old one-shot load truncated at 200 items).
/// Rebuilds from page 0 when access or the filter changes; the grid calls
/// [MediaItemsNotifier.loadMore] as the user approaches the end.
class MediaItemsNotifier extends AsyncNotifier<List<MediaItem>> {
  static const _pageSize = 120;

  int _nextPage = 0;
  bool _hasMore = true;
  bool _loadingMore = false;

  @override
  Future<List<MediaItem>> build() async {
    // Watching resets paging whenever access or filter changes.
    final access = ref.watch(mediaAccessProvider).asData?.value;
    final filter = ref.watch(mediaFilterProvider);
    _nextPage = 0;
    _hasMore = true;
    _loadingMore = false;
    if (access != MediaAccess.authorized && access != MediaAccess.limited) {
      return const [];
    }
    final first = await ref
        .watch(localMediaLibraryProvider)
        .loadPage(filter: filter, page: 0, pageSize: _pageSize);
    _nextPage = 1;
    _hasMore = first.length == _pageSize;
    return first;
  }

  /// Append the next page. Safe to call repeatedly (re-entrancy guarded);
  /// no-op once the end is reached.
  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final current = state.asData?.value;
    if (current == null) return; // initial load still running
    _loadingMore = true;
    try {
      final filter = ref.read(mediaFilterProvider);
      final next = await ref
          .read(localMediaLibraryProvider)
          .loadPage(filter: filter, page: _nextPage, pageSize: _pageSize);
      _nextPage++;
      _hasMore = next.length == _pageSize;
      if (next.isNotEmpty) {
        state = AsyncData([...current, ...next]);
      }
      _log.debug('media page appended', fields: {
        'page': _nextPage - 1,
        'added': next.length,
        'total': (state.asData?.value.length ?? 0),
        'hasMore': _hasMore,
      });
    } catch (e, s) {
      _log.error('media loadMore failed', error: e, stackTrace: s);
      // Keep what we have; a later scroll retries.
    } finally {
      _loadingMore = false;
    }
  }
}

final mediaItemsProvider =
    AsyncNotifierProvider<MediaItemsNotifier, List<MediaItem>>(
        MediaItemsNotifier.new);
