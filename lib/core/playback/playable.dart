import 'package:flutter/foundation.dart';

/// What kind of engine a [Playable] needs.
enum PlayableKind { audio, video }

/// One playable item — THE unit of the centralized playback machinery.
///
/// Every playback surface (local music, a server file, a future movie
/// stream) produces one of these; the player never knows or cares where the
/// bytes come from. This is the client-side twin of the VaultClient seam:
/// it makes "local file vs server stream vs future source" invisible to the
/// UI.
@immutable
class Playable {
  const Playable({
    required this.id,
    required this.kind,
    required this.uri,
    required this.title,
    this.subtitle = '',
    this.album = '',
    this.artwork,
    this.artworkUri,
    this.headers = const {},
  });

  /// Stable identity for "is this the current item" checks. For local music
  /// this is the file path; for server files the node id.
  final String id;

  final PlayableKind kind;

  /// file:// or http(s):// source.
  final Uri uri;

  final String title;

  /// Artist / secondary line.
  final String subtitle;

  final String album;

  /// Embedded artwork bytes, when known (local files).
  final Uint8List? artwork;

  /// Artwork URL for network sources (fetched with [headers]); the player UI
  /// and lock-screen metadata use whichever of the two art fields is set.
  final Uri? artworkUri;

  /// Auth headers for network sources (server streams carry the bearer).
  final Map<String, String> headers;

  bool get isNetwork => uri.scheme == 'http' || uri.scheme == 'https';
}
