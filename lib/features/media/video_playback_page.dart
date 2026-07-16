import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import 'widgets/media_transport_controls.dart';

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
  late final Future<VideoPlayerController> _future =
      ref.read(playbackProvider.notifier).openVideo(widget.item);

  @override
  void dispose() {
    // Leaving the page ends the session. When PiP lands, this becomes
    // conditional: keep the session alive and hand it to the PiP surface.
    ref.read(playbackProvider.notifier).closeVideo();
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
      body: Center(
        child: FutureBuilder<VideoPlayerController>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Text('Playback failed',
                  style: TextStyle(color: Colors.white70));
            }
            final c = snap.data;
            if (c == null) return const CircularProgressIndicator();
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AspectRatio(
                  aspectRatio:
                      c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
                MediaTransportControls(controller: c),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Opens fullscreen video playback for [item] on the root navigator.
Future<void> openVideoPlayback(BuildContext context, Playable item) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => VideoPlaybackPage(item: item)),
  );
}
