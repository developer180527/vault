import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/client/vault_client.dart';
import '../data/torrents.dart';

/// One torrent: what it is, how it's doing, and what you can do to it.
class TorrentTile extends ConsumerWidget {
  const TorrentTile({
    super.key,
    required this.torrent,
    required this.canManage,
  });

  final TorrentEntry torrent;
  final bool canManage;

  Future<void> _act(BuildContext context, WidgetRef ref,
      Future<void> Function(TorrentsApi) op) async {
    try {
      await op(ref.read(vaultClientProvider).torrents);
      ref.invalidate(torrentListProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'.replaceAll('Exception: ', ''))),
        );
      }
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    // Two distinct destructive choices, so they get two distinct buttons
    // rather than a checkbox someone mis-clicks: removing the torrent is
    // recoverable, deleting its data is not.
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove torrent?'),
        content: Text(
          '${torrent.name}\n\n'
          'Removing stops the transfer and any seeding. You can also delete '
          'what it downloaded — that cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('keep'),
            child: const Text('Remove, keep files'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop('data'),
            child: const Text('Remove + delete data'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (!context.mounted) return;
    await _act(context, ref,
        (api) => api.remove(torrent.hash, withData: choice == 'data'));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final t = torrent;

    final stateColor = t.hasError
        ? scheme.error
        : t.isPaused
            ? scheme.onSurfaceVariant
            : t.isDone
                ? scheme.primary
                : scheme.onSurfaceVariant;

    // Secondary line: state, size, then only the figures that mean something
    // right now — an idle torrent shouldn't show a row of zeroes.
    final parts = <String>[
      describeState(t),
      formatBytes(t.size),
      if (formatSpeed(t.dlSpeed).isNotEmpty) '↓ ${formatSpeed(t.dlSpeed)}',
      if (formatSpeed(t.upSpeed).isNotEmpty) '↑ ${formatSpeed(t.upSpeed)}',
      if (!t.isDone && formatEta(t.eta).isNotEmpty) formatEta(t.eta),
      if (t.isDone) 'ratio ${t.ratio.toStringAsFixed(2)}',
      if (!t.isDone && t.seeds + t.peers > 0) '${t.seeds}s / ${t.peers}p',
    ];

    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      title: Text(
        t.name.isEmpty ? t.hash : t.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          // Only show a bar while there's progress to make; a finished torrent
          // that's seeding doesn't need a permanent full bar.
          if (!t.isDone) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: t.isChecking ? null : t.progress,
                minHeight: 4,
                backgroundColor: scheme.surfaceContainerHighest,
                color: t.hasError ? scheme.error : null,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            parts.join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: stateColor),
          ),
        ],
      ),
      trailing: !canManage
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!t.isChecking)
                  IconButton(
                    tooltip: t.isPaused ? 'Resume' : 'Pause',
                    icon: Icon(
                      t.isPaused ? Icons.play_arrow : Icons.pause,
                      size: 20,
                    ),
                    onPressed: () => _act(
                      context,
                      ref,
                      (api) => t.isPaused
                          ? api.resume(t.hash)
                          : api.pause(t.hash),
                    ),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (v) async {
                    switch (v) {
                      case 'recheck':
                        await _act(
                            context, ref, (api) => api.recheck(t.hash));
                      case 'remove':
                        await _remove(context, ref);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'recheck',
                      child: Text('Re-check data'),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove…'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
