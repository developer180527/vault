import 'package:flutter/foundation.dart';

/// A user-owned playlist in the SHARED music catalog: it stores catalog track
/// UUIDs + the owner's UUID server-side, nothing else.
@immutable
class Playlist {
  const Playlist({required this.id, required this.name, this.trackCount = 0});

  final String id;
  final String name;
  final int trackCount;

  factory Playlist.fromJson(Map<String, Object?> j) => Playlist(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    trackCount: (j['track_count'] as num?)?.toInt() ?? 0,
  );

  /// Wire-identical to the server's JSON (snapshot caching round-trip).
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'track_count': trackCount,
  };
}
