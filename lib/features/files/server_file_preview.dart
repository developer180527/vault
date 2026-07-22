import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/client/http_file_repository.dart';
import '../../core/models/file_node.dart';
import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import '../media/video_playback_page.dart';
import 'data/file_browser_controller.dart';
import 'document_viewer_page.dart';

/// Resolves a [FileNode] to its server content URL + bearer, then opens the
/// right in-app preview. The single entry point for both tap and the "Open"
/// context-menu action. On a non-server (mock) repo there's nothing to stream,
/// so it says so rather than failing obscurely.
Future<void> openServerFileNode(
    BuildContext context, WidgetRef ref, FileNode node) async {
  final repo = ref.read(fileRepositoryProvider);
  if (repo is! HttpFileRepository) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Open “${node.name}” — preview not available')),
    );
    return;
  }
  final headers = await repo.authHeader(); // refreshes a stale token
  if (!context.mounted) return;
  await openServerFile(context, ref,
      node: node, contentUri: repo.contentUri(node.id), headers: headers);
}

/// Opens the right preview for a tapped server file, routing through the
/// centralized playback machinery:
///
/// - **audio** → the shared audio queue (gets the mini-player + background
///   playback + lock-screen for free), then the fullscreen music player;
/// - **video** → the shared [VideoPlaybackPage];
/// - **image** → an inline zoomable viewer;
/// - anything else → a short info page.
///
/// Everything streams over the tailnet with the session's bearer header.
Future<void> openServerFile(
  BuildContext context,
  WidgetRef ref, {
  required FileNode node,
  required Uri contentUri,
  required Map<String, String> headers,
}) async {
  switch (node.mediaKind) {
    case FileMediaKind.audio:
      await ref.read(playbackProvider.notifier).playAudioQueue([
        Playable(
          id: node.id,
          kind: PlayableKind.audio,
          uri: contentUri,
          title: node.name,
          headers: headers,
        ),
      ], 0);
      // Audio backgrounds; the mini-player appears. No page push needed.
      return;
    case FileMediaKind.video:
      if (!context.mounted) return;
      await openVideoPlayback(
        context,
        Playable(
          id: node.id,
          kind: PlayableKind.video,
          uri: contentUri,
          title: node.name,
          headers: headers,
        ),
      );
      return;
    case FileMediaKind.image:
      if (!context.mounted) return;
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => _ImagePreview(
              name: node.name, uri: contentUri, headers: headers),
        ),
      );
      return;
    case FileMediaKind.document:
    case FileMediaKind.none:
      // PDFs, markdown, code, and text files get the in-app document viewer;
      // the media_kind heuristic misses some, so route on the filename too.
      if (!context.mounted) return;
      if (isViewableDocument(node.name)) {
        await openDocument(
          context,
          name: node.name,
          uri: contentUri,
          headers: headers,
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No preview for "${node.name}" yet')),
      );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview(
      {required this.name, required this.uri, required this.headers});

  final String name;
  final Uri uri;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.network(
            uri.toString(),
            headers: headers,
            fit: BoxFit.contain,
            loadingBuilder: (c, child, p) =>
                p == null ? child : const CircularProgressIndicator(),
            errorBuilder: (c, e, _) => const Text('Could not load image',
                style: TextStyle(color: Colors.white70)),
          ),
        ),
      ),
    );
  }
}
