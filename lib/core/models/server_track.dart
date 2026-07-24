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
    this.genre = '',
    this.trackNo = 0,
    this.year = 0,
    this.hasArt = false,
    this.artVersion = 0,
    this.streamUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String genre;
  final int trackNo;
  final int year;
  final bool hasArt;

  /// Cover version stamp from the server — folded into the art URL (`?v=`) so
  /// URL-keyed caches refetch the moment an admin uploads new art. 0 on old
  /// servers (no busting; TTL still applies).
  final int artVersion;

  /// Signed, bearer-free stream path (with query) from the server — playback
  /// through it outlives the 15-minute access token, which is what makes
  /// looping/queue-wrap work on long listens. Null on old servers.
  final String? streamUrl;

  factory ServerTrack.fromJson(Map<String, Object?> j) => ServerTrack(
    id: j['id'] as String,
    title: (j['title'] as String?) ?? '',
    artist: (j['artist'] as String?) ?? '',
    album: (j['album'] as String?) ?? '',
    genre: (j['genre'] as String?) ?? '',
    trackNo: (j['track_no'] as num?)?.toInt() ?? 0,
    year: (j['year'] as num?)?.toInt() ?? 0,
    hasArt: (j['has_art'] as bool?) ?? false,
    artVersion: (j['art_version'] as num?)?.toInt() ?? 0,
    streamUrl: j['stream_url'] as String?,
  );

  /// Wire-identical to the server's JSON — snapshot caching round-trips
  /// through the same [ServerTrack.fromJson].
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'genre': genre,
    'track_no': trackNo,
    'year': year,
    'has_art': hasArt,
    if (artVersion != 0) 'art_version': artVersion,
    if (streamUrl != null) 'stream_url': streamUrl,
  };
}
