import 'dart:async';

enum VideoCodec { h264, hevc, vp9, av1 }

enum AudioCodec { aac, mp3, alac, flac, opus }

/// What this device can decode. Drives the client half of the "direct-play
/// first, transcode on demand" strategy: the client reports support and the
/// server decides whether to stream originals or an HLS transcode.
class MediaSupport {
  const MediaSupport({
    required this.video,
    required this.audio,
    required this.hardwareDecode,
  });

  final Set<VideoCodec> video;
  final Set<AudioCodec> audio;

  /// True if decoding is hardware-accelerated (affects battery/thermal choices
  /// and how aggressively we prefer high-bitrate originals).
  final bool hardwareDecode;

  bool get isEmpty => video.isEmpty && audio.isEmpty;
}

/// A media stream's essential decode requirements, as reported by the server's
/// probe of the file.
class MediaTrack {
  const MediaTrack({required this.container, this.video, this.audio});
  final String container; // e.g. mp4, mkv, webm
  final VideoCodec? video;
  final AudioCodec? audio;
}

/// The playback decision for a track given device support.
sealed class PlaybackPlan {
  const PlaybackPlan();
}

/// Stream the original bytes with HTTP Range — the cheap path.
class DirectPlay extends PlaybackPlan {
  const DirectPlay();
}

/// Ask the server to transcode to a profile this device can play.
class NeedsTranscode extends PlaybackPlan {
  const NeedsTranscode(this.targetProfile);
  final String targetProfile; // e.g. 'hls-h264-aac-720p'
}

/// Shared playback decision: direct-play when the device can decode both
/// tracks, else transcode. Host-agnostic, so it lives as a top-level function
/// every implementation reuses rather than reimplements.
PlaybackPlan planPlayback(MediaTrack track, MediaSupport support) {
  final videoOk = track.video == null || support.video.contains(track.video);
  final audioOk = track.audio == null || support.audio.contains(track.audio);
  return videoOk && audioOk
      ? const DirectPlay()
      : const NeedsTranscode('hls-h264-aac-720p');
}

/// Port for device codec capabilities. Implementations probe the platform
/// decoders (Android `MediaCodec`, AVFoundation, browser). Combine [probe] with
/// [planPlayback] to choose direct-play vs transcode.
abstract interface class MediaCodec {
  /// Probe device decoders. Cache the result; it doesn't change at runtime.
  Future<MediaSupport> probe();
}

/// Conservative default: assume only the near-universal h264/aac, software
/// decode. Guarantees playback works (via transcode) until a real probe runs.
class StubMediaCodec implements MediaCodec {
  const StubMediaCodec();

  @override
  Future<MediaSupport> probe() async => const MediaSupport(
        video: {VideoCodec.h264},
        audio: {AudioCodec.aac, AudioCodec.mp3},
        hardwareDecode: false,
      );
}
