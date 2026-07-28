import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/content_upload_engine.dart';
import 'library_curation.dart';

/// The Administrative service: the admin's home for curating the shared
/// library. Two halves — **Uploads** (one resumable queue for music AND
/// movies) and **Library** (fix metadata and artwork on what's already there).
class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.cloud_upload_outlined), text: 'Uploads'),
              Tab(icon: Icon(Icons.tune), text: 'Library'),
            ],
          ),
          const Expanded(
            child: TabBarView(children: [UploadsTab(), LibraryCuration()]),
          ),
        ],
      ),
    );
  }
}

/// The upload queue: pick files, watch them go, pause/resume. Chunked and
/// resumable — a dropped connection costs one 16 MB chunk, and closing the app
/// pauses rather than loses a 10 GB transfer.
class UploadsTab extends ConsumerWidget {
  const UploadsTab({super.key});

  static String fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  Future<void> _pick(WidgetRef ref, UploadKind kind) async {
    // No type filter: macOS has no UTI for Matroska, so a video/* filter greys
    // out the .mkv files this catalog is mostly made of. The server validates
    // the extension and reports what it refused.
    final files = await openFiles();
    if (files.isEmpty) return;
    await ref.read(contentUploadQueueProvider.notifier).add([
      for (final f in files) File(f.path),
    ], kind);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uploads = ref.watch(contentUploadQueueProvider);
    final scheme = Theme.of(context).colorScheme;
    final anyDone = uploads.any((u) => u.status == UploadStatus.done);

    return Column(
      children: [
        _AddBar(
          onAddMusic: () => _pick(ref, UploadKind.music),
          onAddMovies: () => _pick(ref, UploadKind.movies),
          onClearFinished: anyDone
              ? () => ref
                    .read(contentUploadQueueProvider.notifier)
                    .clearFinished()
              : null,
        ),
        const Divider(height: 1),
        Expanded(
          child: uploads.isEmpty
              ? const _Empty()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 120),
                  itemCount: uploads.length + 1,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    if (i == uploads.length) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                        child: Text(
                          'Transfers resume from the last completed chunk if '
                          'anything interrupts them. Closing the app pauses '
                          'them — they pick up where they left off.',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 12.5,
                          ),
                        ),
                      );
                    }
                    return _UploadTile(upload: uploads[i]);
                  },
                ),
        ),
      ],
    );
  }
}

class _AddBar extends StatelessWidget {
  const _AddBar({
    required this.onAddMusic,
    required this.onAddMovies,
    required this.onClearFinished,
  });

  final VoidCallback onAddMusic;
  final VoidCallback onAddMovies;
  final VoidCallback? onClearFinished;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: onAddMusic,
            icon: const Icon(Icons.library_music_outlined, size: 18),
            label: const Text('Add music'),
          ),
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
            onPressed: onAddMovies,
            icon: const Icon(Icons.movie_outlined, size: 18),
            label: const Text('Add movies'),
          ),
          const Spacer(),
          if (onClearFinished != null)
            TextButton(
              onPressed: onClearFinished,
              child: const Text('Clear finished'),
            ),
        ],
      ),
    );
  }
}

class _UploadTile extends ConsumerWidget {
  const _UploadTile({required this.upload});

  final ContentUpload upload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final q = ref.read(contentUploadQueueProvider.notifier);
    final pct = (upload.fraction * 100).toStringAsFixed(0);
    final fmt = UploadsTab.fmtBytes;

    final (IconData icon, Color color, String label) = switch (upload.status) {
      UploadStatus.done => (Icons.check_circle, scheme.primary, 'Done'),
      UploadStatus.failed => (Icons.error_outline, scheme.error, 'Failed'),
      UploadStatus.paused => (
        Icons.pause_circle_outline,
        scheme.onSurfaceVariant,
        'Paused · ${fmt(upload.sent)} of ${fmt(upload.size)}',
      ),
      UploadStatus.uploading => (
        Icons.cloud_upload_outlined,
        scheme.primary,
        '$pct% · ${fmt(upload.sent)} of ${fmt(upload.size)}',
      ),
      UploadStatus.queued => (
        Icons.schedule,
        scheme.onSurfaceVariant,
        'Queued · ${fmt(upload.size)}',
      ),
    };

    return ListTile(
      leading: Icon(icon, color: color),
      title: Row(
        children: [
          Flexible(
            child: Text(
              upload.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          // Which library this lands in — the one thing a merged queue must
          // still make obvious at a glance.
          _KindChip(kind: upload.kind),
        ],
      ),
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
      isThreeLine:
          upload.status == UploadStatus.uploading ||
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

class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});
  final UploadKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        kind.label,
        style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.admin_panel_settings_outlined,
              size: 48,
              color: scheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Add content to your vault',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Pick music or movie files from this device. Uploads are '
              'resumable — a dropped connection costs one chunk, not the '
              'whole transfer.\n\nFor a bulk first import, rsync straight '
              'into the library on the server and hit Scan; it saturates the '
              'link better than any client.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
