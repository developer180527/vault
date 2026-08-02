import 'package:flutter/foundation.dart';

/// What kind of engine a [Playable] needs.
enum PlayableKind { audio, video }

/// One selectable audio track inside a video (Japanese original, English dub…).
///
/// [index] is the per-TYPE ordinal (ffmpeg's `a:0`, `a:1`) — the number the
/// server needs to `-map` the right stream, NOT the container's absolute
/// stream index.
@immutable
class AudioTrackOption {
  const AudioTrackOption({
    required this.index,
    required this.label,
    this.isDefault = false,
  });

  final int index;

  /// Already humanized by whoever built it ("English Dub", "日本語 5.1").
  final String label;
  final bool isDefault;
}

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
    this.audioTracks = const [],
    this.streamFor,
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

  /// Selectable audio tracks. Fewer than two means there's nothing to pick,
  /// and the player hides the control. Any SERVICE can populate this — a
  /// catalog movie from its scan, a Files video from /mediainfo — which is
  /// what makes the language picker source-agnostic.
  final List<AudioTrackOption> audioTracks;

  /// Builds the stream URI for a given audio track and start offset.
  ///
  /// The engines behind [video_player] (AVPlayer/ExoPlayer) expose no API to
  /// select an embedded audio track, so switching means fetching a DIFFERENT
  /// stream: the server remuxes with only the chosen track (`-c copy`, no
  /// re-encode). A remuxed pipe can't serve HTTP Range, hence the explicit
  /// [startSec] — the seek happens server-side.
  ///
  /// Null when the source can't vary (a local file), which also disables the
  /// picker.
  final Uri Function(int audioIndex, int startSec)? streamFor;

  bool get isNetwork => uri.scheme == 'http' || uri.scheme == 'https';

  /// Whether the player should offer an audio-track control.
  bool get canSwitchAudio => audioTracks.length > 1 && streamFor != null;

  Playable copyWith({Uri? uri}) => Playable(
    id: id,
    kind: kind,
    uri: uri ?? this.uri,
    title: title,
    subtitle: subtitle,
    album: album,
    artwork: artwork,
    artworkUri: artworkUri,
    headers: headers,
    artHeaders: artHeaders,
    refreshUri: refreshUri,
    audioTracks: audioTracks,
    streamFor: streamFor,
  );
}
