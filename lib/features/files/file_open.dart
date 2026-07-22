import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/models/file_node.dart';
import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import 'document_viewer_page.dart';
import 'file_image_viewer_page.dart';
import 'file_video_viewer_page.dart';

/// Open a server file IN-APP, routed by its media kind:
///
/// - **image** → a pinch-zoom viewer,
/// - **video** → the central video player (resume-aware),
/// - **audio** → enqueued into the audio player (mini-player appears),
/// - **document** (pdf/markdown/code/text) → the document viewer,
/// - anything else → a hint to use Download (nothing can render it in-app).
///
/// Bytes come from `/v1/files/{id}/content` with the bearer, refreshed up front
/// so a long video/read doesn't die on a 15-minute token. Files are bearer-only
/// (no signed URLs), so the audio path uses the bearer header directly.
Future<void> openFileNode(
    BuildContext context, WidgetRef ref, FileNode node) async {
  final messenger = ScaffoldMessenger.of(context);

  var session = ref.read(sessionProvider).asData?.value;
  if (session == null) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Not connected to a server.')));
    return;
  }
  if (session.accessExpires.isBefore(DateTime.now())) {
    session = await ref.read(sessionProvider.notifier).refresh();
    if (session == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Session expired — reconnect.')));
      return;
    }
  }

  final uri = session.api('/v1/files/${node.id}/content');
  final headers = {'Authorization': 'Bearer ${session.accessToken}'};
  if (!context.mounted) return;

  switch (node.mediaKind) {
    case FileMediaKind.image:
      await openFileImage(context, name: node.name, uri: uri, headers: headers);
    case FileMediaKind.video:
      await openFileVideo(context,
          id: node.id, name: node.name, uri: uri, headers: headers);
    case FileMediaKind.audio:
      await ref.read(playbackProvider.notifier).playAudioQueue([
        Playable(
          id: node.id,
          kind: PlayableKind.audio,
          uri: uri,
          title: node.name,
          headers: headers,
        ),
      ], 0);
      messenger.showSnackBar(
          SnackBar(content: Text('Playing “${node.name}”.')));
    case FileMediaKind.document:
    case FileMediaKind.none:
      if (isViewableDocument(node.name)) {
        await openDocument(context,
            name: node.name, uri: uri, headers: headers);
      } else {
        messenger.showSnackBar(SnackBar(
            content: Text(
                'No in-app preview for “${node.name}” — use Download to open it.')));
      }
  }
}
