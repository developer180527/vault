import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

/// Opens a full-screen, pinch-zoom viewer for a server image file.
Future<void> openFileImage(
  BuildContext context, {
  required String name,
  required Uri uri,
  required Map<String, String> headers,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          FileImageViewerPage(name: name, uri: uri, headers: headers),
    ),
  );
}

/// Full-screen image viewer: pinch-zoom / double-tap via PhotoView, streaming
/// the bytes from the server with the bearer. No local library involvement —
/// this is a plain network image, so it's independent of the on-device photo
/// viewer (which is bound to local assets).
class FileImageViewerPage extends StatelessWidget {
  const FileImageViewerPage({
    super.key,
    required this.name,
    required this.uri,
    required this.headers,
  });

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
      body: PhotoView(
        imageProvider: NetworkImage(uri.toString(), headers: headers),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        loadingBuilder: (_, _) =>
            const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, _, _) => const Center(
          child: Text('Could not load image',
              style: TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }
}
