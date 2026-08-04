import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import '../movies/data/movie_playback.dart';
import 'mpv_playback_page.dart';
import 'widgets/video_surface.dart';

/// The single fullscreen video surface for the whole app — server files,
/// movies (later), any [Playable] of kind video. It does NOT own the player:
/// [PlaybackController] does, so native Picture-in-Picture (a later platform
/// hook on that one controller) can keep playing when this page is gone.
///
/// Opening is centralized: call [openVideoPlayback] from anywhere.
class VideoPlaybackPage extends ConsumerStatefulWidget {
  const VideoPlaybackPage({super.key, required this.item});

  final Playable item;

  @override
  ConsumerState<VideoPlaybackPage> createState() => _VideoPlaybackPageState();
}

class _VideoPlaybackPageState extends ConsumerState<VideoPlaybackPage> {
  // Captured once: `ref` is unusable in dispose() — it throws and aborts the
  // teardown, leaking the session (the audio-persistence bug class).
  late final PlaybackController _playback =
      ref.read(playbackProvider.notifier);
  late Future<VideoPlayerController> _future =
      _playback.openVideo(widget.item);

  @override
  void dispose() {
    // Leaving the page ends the session — unless a newer session superseded
    // it. When PiP lands, this becomes conditional: hand off instead of close.
    _playback.closeVideo(onlyIf: widget.item.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.item.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<VideoPlayerController>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
              child: Text('Playback failed',
                  style: TextStyle(color: Colors.white70)),
            );
          }
          final c = snap.data;
          if (c == null) {
            return const Center(child: CircularProgressIndicator());
          }
          // Audio-language picker for ANY source that declares tracks — a
          // catalog movie, a dual-audio MKV sitting in Files, anything later.
          // The controller performs the swap (it owns the session).
          return VideoSurface(
            controller: c,
            title: widget.item.title,
            audioTracks: widget.item.canSwitchAudio
                ? widget.item.audioTracks
                : const [],
            currentAudioTrack: _playback.videoAudioTrack,
            onSelectAudio: (i) async {
              final next = await _playback.switchVideoAudio(i);
              if (mounted && next != null) setState(() => _future = Future.value(next));
            },
          );
        },
      ),
    );
  }
}

/// Containers AVPlayer/ExoPlayer cannot open. A file in one of these has to go
/// to libmpv — the server-remux workaround produces a pipe that can't answer
/// Range requests, which AVPlayer rejects outright.
const _foreignContainers = [
  '.mkv', '.webm', '.avi', '.ts', '.m2ts', '.mts', '.wmv', '.flv', '.ogv',
  '.vob', '.rmvb', '.divx',
];

/// Opens fullscreen video playback for [item] on the root navigator, choosing
/// the engine automatically.
///
/// Same rule as the movie catalog: keep the native engine where it genuinely
/// works (hardware decode, system PiP), and hand everything it can't open to
/// libmpv. Here the decision is made from the file extension rather than a
/// probe, so opening never waits on a network round trip.
Future<void> openVideoPlayback(BuildContext context, Playable item) {
  final name = item.title.toLowerCase();
  final path = item.uri.path.toLowerCase();
  final foreign = _foreignContainers
      .any((ext) => name.endsWith(ext) || path.endsWith(ext));
  final useMpv = libmpvAvailable && foreign;
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => useMpv
          ? MpvPlaybackPage(item: item)
          : VideoPlaybackPage(item: item),
    ),
  );
}
