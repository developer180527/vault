import '../../../core/models/server_movie.dart';
import '../../../core/platform/media_codec.dart';

/// How to fetch a movie's bytes for playback, given the device's decoders.
///
///  * [direct]    — original file, HTTP Range seeking (cheap, no ffmpeg).
///  * [remux]     — codecs the device CAN decode but a container it can't open
///                  (e.g. H.264/AAC in MKV). Server does a zero-CPU `-c copy`
///                  rewrite to fragmented MP4.
///  * [transcode] — a codec the device can't decode at all (HEVC/VP9/AV1, or
///                  AC-3/DTS/… audio). Server re-encodes to H.264/AAC. CPU-heavy.
enum MovieStreamMode { direct, remux, transcode }

/// Containers a mobile/desktop video engine opens natively (AVPlayer/ExoPlayer).
/// ffprobe reports comma lists ("mov,mp4,m4a,3gp,3g2,mj2"), so we substring-match.
const _nativeContainers = ['mp4', 'mov', 'm4v'];

VideoCodec? _videoCodec(String v) => switch (v.toLowerCase()) {
      'h264' || 'avc' || 'avc1' => VideoCodec.h264,
      'hevc' || 'h265' || 'hvc1' => VideoCodec.hevc,
      'vp9' => VideoCodec.vp9,
      'av1' => VideoCodec.av1,
      _ => null, // unknown → treat as undecodable → transcode
    };

AudioCodec? _audioCodec(String a) => switch (a.toLowerCase()) {
      'aac' => AudioCodec.aac,
      'mp3' => AudioCodec.mp3,
      'alac' => AudioCodec.alac,
      'flac' => AudioCodec.flac,
      'opus' => AudioCodec.opus,
      _ => null, // ac3/eac3/dts/truehd/… → undecodable → transcode
    };

bool _containerIsNative(String container) {
  final c = container.toLowerCase();
  return _nativeContainers.any(c.contains);
}

/// Decide how to stream [movie] with audio track [audioIndex] on a device
/// with [support]. Extends [planPlayback] with container awareness: compatible
/// codecs in a non-native container need a remux, not a full transcode.
MovieStreamMode movieStreamMode(
  ServerMovie movie,
  MediaSupport support, {
  int audioIndex = 0,
}) {
  final video = _videoCodec(movie.vcodec);
  // Unknown/unlisted video codec is undecodable by definition here.
  final videoOk = video != null && support.video.contains(video);

  // Which audio track actually plays. When the codec string is empty (older
  // snapshots without per-track codecs), assume the near-universal AAC so we
  // don't force a needless transcode.
  final track = (audioIndex >= 0 && audioIndex < movie.audio.length)
      ? movie.audio[audioIndex]
      : null;
  final audioStr = track?.codec ?? '';
  final audio = audioStr.isEmpty ? AudioCodec.aac : _audioCodec(audioStr);
  final audioOk = audio != null && support.audio.contains(audio);

  if (!videoOk || !audioOk) return MovieStreamMode.transcode;
  if (!_containerIsNative(movie.container)) return MovieStreamMode.remux;
  return MovieStreamMode.direct;
}
