import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/models/file_node.dart';
import '../media/widgets/media_transport_controls.dart';

/// Streams a server file for preview: images inline, video/audio with a
/// player, everything over the tailnet with the session's bearer header.
/// Range requests (server-side) make video seeking work without downloading
/// the whole file.
class ServerFilePreview extends StatelessWidget {
  const ServerFilePreview({
    super.key,
    required this.node,
    required this.contentUri,
    required this.headers,
  });

  final FileNode node;
  final Uri contentUri;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(node.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    switch (node.mediaKind) {
      case FileMediaKind.image:
        return InteractiveViewer(
          child: Image.network(
            contentUri.toString(),
            headers: headers,
            fit: BoxFit.contain,
            loadingBuilder: (c, child, p) => p == null
                ? child
                : const CircularProgressIndicator(),
            errorBuilder: (c, e, _) =>
                _message(context, 'Could not load image'),
          ),
        );
      case FileMediaKind.video:
      case FileMediaKind.audio:
        return _NetworkPlayer(uri: contentUri, headers: headers);
      default:
        return _message(context,
            'No preview for this file type yet.\n${_prettySize(node.size)}');
    }
  }

  Widget _message(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.all(32),
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70)),
      );

  static String _prettySize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var size = bytes / 1024;
    var i = 0;
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${units[i]}';
  }
}

/// Video/audio streamed from the server with auth headers.
class _NetworkPlayer extends StatefulWidget {
  const _NetworkPlayer({required this.uri, required this.headers});

  final Uri uri;
  final Map<String, String> headers;

  @override
  State<_NetworkPlayer> createState() => _NetworkPlayerState();
}

class _NetworkPlayerState extends State<_NetworkPlayer> {
  VideoPlayerController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final c = VideoPlayerController.networkUrl(widget.uri,
        httpHeaders: widget.headers);
    try {
      await c.initialize();
      await c.play();
      if (mounted) setState(() => _controller = c);
    } catch (e) {
      await c.dispose();
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Text('Playback failed',
          style: TextStyle(color: Colors.white70));
    }
    final c = _controller;
    if (c == null) return const CircularProgressIndicator();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AspectRatio(
          aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
          child: VideoPlayer(c),
        ),
        MediaTransportControls(controller: c),
      ],
    );
  }
}
