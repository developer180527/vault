import 'package:flutter/foundation.dart';

/// One backed-up original on the server — the client twin of vaultd's
/// store.Photo JSON.
@immutable
class ServerPhoto {
  const ServerPhoto({
    required this.id,
    required this.name,
    required this.hash,
    this.size = 0,
    this.mime = '',
    this.kind = 'photo',
    this.takenAt = 0,
    this.uploadedAt = 0,
    this.hasThumb = false,
  });

  final String id;
  final String name;
  final String hash;
  final int size;
  final String mime;
  final String kind; // photo | video
  final int takenAt; // unix seconds, 0 = unknown
  final int uploadedAt;
  final bool hasThumb;

  factory ServerPhoto.fromJson(Map<String, Object?> j) => ServerPhoto(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    hash: (j['hash'] as String?) ?? '',
    size: (j['size'] as num?)?.toInt() ?? 0,
    mime: (j['mime'] as String?) ?? '',
    kind: (j['kind'] as String?) ?? 'photo',
    takenAt: (j['taken_at'] as num?)?.toInt() ?? 0,
    uploadedAt: (j['uploaded_at'] as num?)?.toInt() ?? 0,
    hasThumb: (j['has_thumb'] as bool?) ?? false,
  );

  /// Best display date: capture time, else upload time.
  DateTime get when => DateTime.fromMillisecondsSinceEpoch(
      (takenAt > 0 ? takenAt : uploadedAt) * 1000);
}

/// One page of the server-side backup listing plus whole-store totals.
@immutable
class PhotoBackupListing {
  const PhotoBackupListing({
    required this.photos,
    required this.total,
    required this.totalBytes,
  });

  final List<ServerPhoto> photos;
  final int total;
  final int totalBytes;
}
