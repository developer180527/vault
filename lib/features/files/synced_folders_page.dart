import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/client/vault_client.dart';
import 'data/sync_engine.dart';

/// Opens the synced-folders manager over the shell.
void openSyncedFolders(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const SyncedFoldersPage()),
  );
}

/// Lists folders synced into the vault with their provenance, and lets the
/// user push a new one. A synced folder is a real Files-zone folder reachable
/// from any device; this page adds the "which device, when" context.
class SyncedFoldersPage extends ConsumerWidget {
  const SyncedFoldersPage({super.key});

  static IconData _iconFor(String platform) => switch (platform) {
    'ios' || 'android' => Icons.smartphone,
    'macos' => Icons.laptop_mac,
    'windows' => Icons.laptop_windows,
    'linux' => Icons.laptop,
    _ => Icons.devices_other,
  };

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  static String _ago(int unixSecs) {
    if (unixSecs == 0) return 'never';
    final d = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000));
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${(d.inDays / 30).floor()}mo ago';
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    try {
      final id = await pickAndSyncFolder(ref);
      if (id != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Folder synced to your vault.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(syncedFoldersProvider);
    final progress = ref.watch(syncProgressProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Synced folders')),
      floatingActionButton: progress == null
          ? FloatingActionButton.extended(
              onPressed: () => _sync(context, ref),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Sync a folder'),
            )
          : null,
      body: Column(
        children: [
          if (progress != null)
            Material(
              color: scheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Syncing "${progress.folder}"…',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: progress.fraction),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${progress.done} of ${progress.total}'
                            '${progress.current.isEmpty ? '' : ' — ${progress.current}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              ref.read(syncProgressProvider.notifier).cancel(),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Unavailable: $e')),
              data: (folders) => folders.isEmpty
                  ? _EmptyState(onSync: () => _sync(context, ref))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
                      itemCount: folders.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _FolderTile(
                        folder: folders[i],
                        iconFor: _iconFor,
                        fmtBytes: _fmtBytes,
                        ago: _ago,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderTile extends ConsumerWidget {
  const _FolderTile({
    required this.folder,
    required this.iconFor,
    required this.fmtBytes,
    required this.ago,
  });

  final SyncedFolderInfo folder;
  final IconData Function(String) iconFor;
  final String Function(int) fmtBytes;
  final String Function(int) ago;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop syncing "${folder.name}"?'),
        content: const Text(
            'The folder and its files stay in your Files — only the sync '
            'record is removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Stop syncing')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(vaultClientProvider).sync.delete(folder.id);
    ref.invalidate(syncedFoldersProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(iconFor(folder.originPlatform),
            size: 20, color: scheme.onSurfaceVariant),
      ),
      title: Text(folder.name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${folder.fileCount} files · ${fmtBytes(folder.totalBytes)}\n'
        'From ${folder.originDevice.isEmpty ? folder.originPlatform : folder.originDevice}'
        ' · synced ${ago(folder.lastSyncAt)}',
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
      ),
      isThreeLine: true,
      trailing: IconButton(
        icon: const Icon(Icons.more_vert),
        onPressed: () => _delete(context, ref),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSync});
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sync, size: 48, color: scheme.primary),
            const SizedBox(height: 16),
            Text('Sync a folder to your vault',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Pick a folder on this device. Its files land in your vault, '
              'reachable from every device you sign in on.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onSync,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Sync a folder'),
            ),
          ],
        ),
      ),
    );
  }
}
