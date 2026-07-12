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

/// The media grid contents for the current filter. Only loads once access is
/// granted; re-runs when the filter changes.
final mediaItemsProvider = FutureProvider<List<MediaItem>>((ref) async {
  final access = ref.watch(mediaAccessProvider).asData?.value;
  if (access != MediaAccess.authorized && access != MediaAccess.limited) {
    return const [];
  }
  final filter = ref.watch(mediaFilterProvider);
  return ref.watch(localMediaLibraryProvider).load(filter: filter);
});
