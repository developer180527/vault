import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/movie_upload_engine.dart';

/// Opens the admin movie uploader (desktop only).
void openMovieUploads(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const MovieUploadsPage()),
  );
}

/// The admin's movie uploader: pick files, watch them go, pause/resume.
/// Chunked and resumable — a dropped connection costs one 16 MB chunk, and
/// closing the app mid-transfer doesn't lose a 10 GB upload.
class MovieUploadsPage extends ConsumerWidget {
  const MovieUploadsPage({super.key});

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  Future<void> _pick(WidgetRef ref) async {
    // No type filter: macOS has no UTI for Matroska, so a video/* filter
    // greys out the .mkv files this catalog is mostly made of. The server
    // validates the extension and reports what it refused.
    final files = await openFiles();
    if (files.isEmpty) return;
    await ref
        .read(movieUploadQueueProvider.notifier)
        .add([for (final f in files) File(f.path)]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uploads = ref.watch(movieUploadQueueProvider);
    final scheme = Theme.of(context).colorScheme;
    final active = uploads.where((u) =>
        u.status == UploadStatus.uploading ||
        u.status == UploadStatus.queued);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload movies'),
        actions: [
          if (uploads.any((u) => u.status == UploadStatus.done))
            TextButton(
              onPressed: () =>
                  ref.read(movieUploadQueueProvider.notifier).clearFinished(),
              child: const Text('Clear finished'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _pick(ref),
        icon: const Icon(Icons.add),
        label: const Text('Add files'),
      ),
      body: uploads.isEmpty
          ? _Empty(onPick: () => _pick(ref))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
              itemCount: uploads.length + 1,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == uploads.length) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: Text(
                      active.isEmpty
                          ? 'Uploads resume automatically if the connection '
                              'drops. Closing the app pauses them — they pick '
                              'up where they left off.'
                          : 'Keep this window open. Transfers resume from the '
                              'last completed chunk if anything interrupts them.',
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 12.5),
                    ),
                  );
                }
                return _UploadTile(
                    upload: uploads[i], fmtBytes: _fmtBytes);
              },
            ),
    );
  }
}

class _UploadTile extends ConsumerWidget {
  const _UploadTile({required this.upload, required this.fmtBytes});

  final MovieUpload upload;
  final String Function(int) fmtBytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final q = ref.read(movieUploadQueueProvider.notifier);
    final pct = (upload.fraction * 100).toStringAsFixed(0);

    final (IconData icon, Color color, String label) = switch (upload.status) {
      UploadStatus.done => (Icons.check_circle, scheme.primary, 'Done'),
      UploadStatus.failed => (Icons.error_outline, scheme.error, 'Failed'),
      UploadStatus.paused => (Icons.pause_circle_outline,
          scheme.onSurfaceVariant, 'Paused'),
      UploadStatus.uploading => (Icons.cloud_upload_outlined, scheme.primary,
          '$pct% · ${fmtBytes(upload.sent)} of ${fmtBytes(upload.size)}'),
      UploadStatus.queued => (Icons.schedule, scheme.onSurfaceVariant,
          'Queued · ${fmtBytes(upload.size)}'),
    };

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(upload.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            upload.status == UploadStatus.failed && upload.error.isNotEmpty
                ? upload.error
                : label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              color: upload.status == UploadStatus.failed
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            ),
          ),
          if (upload.status == UploadStatus.uploading ||
              upload.status == UploadStatus.paused) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: upload.fraction,
                minHeight: 4,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
        ],
      ),
      isThreeLine: upload.status == UploadStatus.uploading ||
          upload.status == UploadStatus.paused,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (upload.status == UploadStatus.uploading)
            IconButton(
              tooltip: 'Pause',
              icon: const Icon(Icons.pause),
              onPressed: () => q.pause(upload.localPath),
            ),
          if (upload.status == UploadStatus.paused ||
              upload.status == UploadStatus.failed)
            IconButton(
              tooltip: 'Resume',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => q.resume(upload.localPath),
            ),
          if (upload.status != UploadStatus.done)
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: () => q.cancel(upload.localPath),
            ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onPick});
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_creation_outlined, size: 48, color: scheme.primary),
            const SizedBox(height: 16),
            Text('Upload movies to your vault',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Large files are sent in chunks, so a dropped connection only '
              'costs the current chunk — not the whole transfer. Uploads '
              'resume where they left off, even after restarting the app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.add),
              label: const Text('Choose files'),
            ),
          ],
        ),
      ),
    );
  }
}
