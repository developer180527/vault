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
    this.artHeaders = const {},
    this.refreshUri,
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

  /// Auth headers for the STREAM request. Empty for a signed (bearer-free)
  /// URL — and empty is what matters: passing headers to `AudioSource.uri`
  /// forces just_audio's localhost header-injection proxy, which serializes
  /// Range and makes streaming sluggish. A signed URL needs none, so the
  /// native player (AVPlayer/ExoPlayer) streams the origin directly.
  final Map<String, String> headers;

  /// Auth headers for the ARTWORK request only (lock-screen/notification art).
  /// Kept separate from [headers] so a bearer-free stream can still fetch
  /// bearer-gated art without dragging the stream back through the proxy.
  final Map<String, String> artHeaders;

  /// Optional: fetch a FRESH source URI for this item. Called once as a
  /// retry if the initial load fails — the escape hatch for a signed URL that
  /// went stale (>24h cached listing), so playback re-signs instead of
  /// silently 401'ing. Null when there's nothing fresher to fetch.
  final Future<Uri?> Function()? refreshUri;

  bool get isNetwork => uri.scheme == 'http' || uri.scheme == 'https';
}
