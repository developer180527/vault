import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:photo_manager/photo_manager.dart';

import '../../../core/platform/platform_info.dart';

/// The user's grant state for on-device media. Mirrors the OS: [limited] is the
/// iOS "selected photos" case, which we support explicitly.
enum MediaAccess { authorized, limited, denied, unavailable }

enum MediaKind { image, video }

/// What the filter pill is set to.
enum MediaFilter {
  all('All', Icons.grid_view_outlined),
  photos('Photos', Icons.photo_outlined),
  videos('Videos', Icons.videocam_outlined),
  music('Music', Icons.music_note_outlined);

  const MediaFilter(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// One on-device media item. Wraps photo_manager's [AssetEntity] but keeps the
/// UI talking to our own type; thumbnail bytes are fetched lazily on demand.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.kind,
    required this.asset,
    this.duration,
  });

  final String id;
  final MediaKind kind;
  final Duration? duration;
  final AssetEntity asset;
}

/// Port for reading the local photo/video library. Implemented by
/// [PhotoManagerLibrary] on Android/iOS/macOS and [UnsupportedMediaLibrary]
/// everywhere else (web, Windows, Linux, tests).
abstract interface class LocalMediaLibrary {
  bool get isSupported;

  /// Requests access (shows the OS permission dialog the first time) and maps
  /// the result to [MediaAccess]. Returns [MediaAccess.unavailable] on hosts
  /// without a photo library.
  Future<MediaAccess> requestAccess();

  /// Opens the OS settings so the user can change a denied grant.
  Future<void> openSettings();

  /// iOS "limited" mode: lets the user add more photos to the selection.
  Future<void> presentLimitedPicker();

  Future<List<MediaItem>> load({required MediaFilter filter, int limit = 200});

  Future<Uint8List?> thumbnail(MediaItem item, {int size = 300});

  /// Full-resolution bytes for a photo, for the fullscreen viewer.
  Future<Uint8List?> fullImage(MediaItem item);

  /// A playable local file path for a video (may materialize from the OS photo
  /// store). Null if unavailable.
  Future<String?> videoPath(MediaItem item);
}

class PhotoManagerLibrary implements LocalMediaLibrary {
  const PhotoManagerLibrary();

  @override
  bool get isSupported =>
      !kIsWeb && (isMacOS || isAndroidOrIOS);

  @override
  Future<MediaAccess> requestAccess() async {
    if (!isSupported) return MediaAccess.unavailable;
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      return switch (ps) {
        PermissionState.authorized => MediaAccess.authorized,
        PermissionState.limited => MediaAccess.limited,
        _ => MediaAccess.denied,
      };
    } catch (_) {
      // Plugin unavailable (e.g. widget tests) → degrade, don't crash.
      return MediaAccess.unavailable;
    }
  }

  @override
  Future<void> openSettings() => PhotoManager.openSetting();

  @override
  Future<void> presentLimitedPicker() => PhotoManager.presentLimited();

  @override
  Future<List<MediaItem>> load({
    required MediaFilter filter,
    int limit = 200,
  }) async {
    // Music is sourced from a chosen folder, not the photo library, so it never
    // reaches here — but the switch must be exhaustive.
    if (filter == MediaFilter.music) return const [];
    final type = switch (filter) {
      MediaFilter.all => RequestType.common,
      MediaFilter.photos => RequestType.image,
      MediaFilter.videos => RequestType.video,
      MediaFilter.music => RequestType.common,
    };
    final albums = await PhotoManager.getAssetPathList(
      type: type,
      onlyAll: true,
    );
    if (albums.isEmpty) return const [];
    final assets =
        await albums.first.getAssetListPaged(page: 0, size: limit);
    return [
      for (final a in assets)
        MediaItem(
          id: a.id,
          kind: a.type == AssetType.video ? MediaKind.video : MediaKind.image,
          duration: a.type == AssetType.video
              ? Duration(seconds: a.duration)
              : null,
          asset: a,
        ),
    ];
  }

  @override
  Future<Uint8List?> thumbnail(MediaItem item, {int size = 300}) =>
      item.asset.thumbnailDataWithSize(ThumbnailSize.square(size));

  @override
  Future<Uint8List?> fullImage(MediaItem item) => item.asset.originBytes;

  @override
  Future<String?> videoPath(MediaItem item) async =>
      (await item.asset.file)?.path;
}

/// Fallback where there is no photo library. Reports unsupported so the UI can
/// show an explanatory state instead of an empty grid.
class UnsupportedMediaLibrary implements LocalMediaLibrary {
  const UnsupportedMediaLibrary();

  @override
  bool get isSupported => false;

  @override
  Future<MediaAccess> requestAccess() async => MediaAccess.unavailable;

  @override
  Future<void> openSettings() async {}

  @override
  Future<void> presentLimitedPicker() async {}

  @override
  Future<List<MediaItem>> load({
    required MediaFilter filter,
    int limit = 200,
  }) async =>
      const [];

  @override
  Future<Uint8List?> thumbnail(MediaItem item, {int size = 300}) async => null;

  @override
  Future<Uint8List?> fullImage(MediaItem item) async => null;

  @override
  Future<String?> videoPath(MediaItem item) async => null;
}
