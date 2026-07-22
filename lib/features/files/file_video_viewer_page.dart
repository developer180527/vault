import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import '../media/widgets/video_surface.dart';

/// Opens a server video file full-screen through the central player.
Future<void> openFileVideo(
  BuildContext context, {
  required String id,
  required String name,
  required Uri uri,
  required Map<String, String> headers,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          FileVideoViewerPage(id: id, name: name, uri: uri, headers: headers),
    ),
  );
}

/// Full-screen video viewer for a server file. Plays through the SAME central
/// [PlaybackController] as movies and the photo viewer, so there's one video
/// session (audio pauses, resume position is remembered) and no duplicate
/// engines. Direct-play only — a codec the device can't decode fails gracefully
/// (files have no transcode endpoint; that's a movie-catalog feature).
class FileVideoViewerPage extends ConsumerStatefulWidget {
  const FileVideoViewerPage({
    super.key,
    required this.id,
    required this.name,
    required this.uri,
    required this.headers,
  });

  final String id;
  final String name;
  final Uri uri;
  final Map<String, String> headers;

  @override
  ConsumerState<FileVideoViewerPage> createState() =>
      _FileVideoViewerPageState();
}

class _FileVideoViewerPageState extends ConsumerState<FileVideoViewerPage> {
  // Captured once: `ref` is unusable in dispose() (throws and aborts teardown).
  late final PlaybackController _playback = ref.read(playbackProvider.notifier);
  late final Future<VideoPlayerController> _future = _playback.openVideo(
    Playable(
      id: widget.id,
      kind: PlayableKind.video,
      uri: widget.uri,
      title: widget.name,
      headers: widget.headers,
    ),
  );

  @override
  void dispose() {
    _playback.closeVideo(onlyIf: widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<VideoPlayerController>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
              child: Text('Video unavailable — this format may not be supported.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70)),
            );
          }
          final controller = snap.data;
          if (controller == null) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.white));
          }
          return VideoSurface(controller: controller, title: widget.name);
        },
      ),
    );
  }
}
