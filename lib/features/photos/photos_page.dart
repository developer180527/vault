import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/data/local_media_library.dart';
import '../media/data/media_providers.dart';
import 'data/backup_engine.dart';

/// The Photos service page (M3, simple phase): camera-roll → server backup.
/// A status card with live progress, the auto-backup toggle, and the last few
/// backed-up originals as a confirmation surface. The browsable timeline
/// arrives with the thumbnail pipeline; this page is about TRUST — seeing
/// that your photos are safe on your own hardware.
class PhotosBackupPage extends ConsumerWidget {
  const PhotosBackupPage({super.key});

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Arms the auto-run listener (no-op unless enabled + connected).
    ref.watch(autoBackupTriggerProvider);

    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(backupEngineProvider);
    final auto = ref.watch(autoBackupPrefProvider).asData?.value ?? false;
    final listing = ref.watch(backupListingProvider).asData?.value;
    final access = ref.watch(mediaAccessProvider).asData?.value;
    final running = state.phase == BackupPhase.scanning ||
        state.phase == BackupPhase.uploading;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
        children: [
          Text('Backup', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Originals from this device, stored on your own server.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          // ---- status card ----
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        switch (state.phase) {
                          BackupPhase.done => Icons.cloud_done_outlined,
                          BackupPhase.error => Icons.cloud_off_outlined,
                          BackupPhase.idle => Icons.cloud_outlined,
                          _ => Icons.cloud_upload_outlined,
                        },
                        color: state.phase == BackupPhase.error
                            ? scheme.error
                            : scheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          switch (state.phase) {
                            BackupPhase.idle => 'Ready to back up',
                            BackupPhase.scanning => 'Scanning camera roll…',
                            BackupPhase.uploading => 'Backing up…',
                            BackupPhase.done => 'Backed up',
                            BackupPhase.error => 'Backup incomplete',
                          },
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (!running)
                        FilledButton.tonal(
                          onPressed: () =>
                              ref.read(backupEngineProvider.notifier).run(),
                          child: const Text('Back up now'),
                        ),
                    ],
                  ),
                  if (running) ...[
                    const SizedBox(height: 14),
                    LinearProgressIndicator(
                      value: state.found == 0
                          ? null
                          : (state.done / state.found).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      state.current.isEmpty
                          ? '${state.done} of ${state.found}'
                          : '${state.done} of ${state.found} — ${state.current}',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (state.error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      state.error,
                      style: TextStyle(color: scheme.error, fontSize: 13),
                    ),
                  ],
                  if (listing != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      '${listing.total} items on the server'
                      ' · ${_fmtBytes(listing.totalBytes)}',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ---- auto-backup toggle ----
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              title: const Text('Back up automatically'),
              subtitle: const Text(
                'Runs when you open the app while connected to your Vault.',
              ),
              value: auto,
              onChanged: (v) =>
                  ref.read(autoBackupPrefProvider.notifier).set(v),
            ),
          ),

          if (access == MediaAccess.denied) ...[
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              color: scheme.errorContainer,
              child: ListTile(
                leading: Icon(Icons.no_photography_outlined,
                    color: scheme.onErrorContainer),
                title: Text(
                  'Photo access denied',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
                subtitle: Text(
                  'Allow photo library access in Settings to back up.',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
                onTap: () =>
                    ref.read(localMediaLibraryProvider).openSettings(),
              ),
            ),
          ],

          // ---- recent backups ----
          if (listing != null && listing.photos.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'Recently backed up',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            for (final p in listing.photos)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  p.kind == 'video'
                      ? Icons.videocam_outlined
                      : Icons.photo_outlined,
                  color: scheme.onSurfaceVariant,
                ),
                title: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_fmtBytes(p.size)),
                dense: true,
              ),
          ],
        ],
      ),
    );
  }
}
