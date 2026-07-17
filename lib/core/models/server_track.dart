import 'package:flutter/foundation.dart';

/// One track in the SERVER's music library (docs/MUSIC.md) — the client-side
/// twin of vaultd's store.Track JSON.
@immutable
class ServerTrack {
  const ServerTrack({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.trackNo = 0,
    this.year = 0,
    this.hasArt = false,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final int trackNo;
  final int year;
  final bool hasArt;

  factory ServerTrack.fromJson(Map<String, Object?> j) => ServerTrack(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        artist: (j['artist'] as String?) ?? '',
        album: (j['album'] as String?) ?? '',
        trackNo: (j['track_no'] as num?)?.toInt() ?? 0,
        year: (j['year'] as num?)?.toInt() ?? 0,
        hasArt: (j['has_art'] as bool?) ?? false,
      );
}
