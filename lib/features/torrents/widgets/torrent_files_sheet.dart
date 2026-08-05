import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/client/vault_client.dart';
import '../data/torrents.dart';

/// Choose which files inside a torrent to keep.
///
/// Worth knowing what this actually does: unticking a file asks qBittorrent not
/// to fetch it, but that's only a bandwidth saving and qBittorrent doesn't
/// reliably honour it. The guarantee comes from the server, which records the
/// choice and imports only these files no matter what ends up on disk. The
/// wording below says so, because "why is that file still there?" is otherwise
/// a mystery.
Future<void> openTorrentFiles(
  BuildContext context,
  WidgetRef ref,
  TorrentEntry torrent,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _FilesDialog(torrent: torrent),
  );
  ref.invalidate(torrentListProvider);
}

class _FilesDialog extends ConsumerStatefulWidget {
  const _FilesDialog({required this.torrent});
  final TorrentEntry torrent;

  @override
  ConsumerState<_FilesDialog> createState() => _FilesDialogState();
}

class _FilesDialogState extends ConsumerState<_FilesDialog> {
  List<TorrentFileEntry>? _files;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final files = await ref
          .read(vaultClientProvider)
          .torrents
          .files(widget.torrent.hash);
      // Biggest first: the thing you actually wanted is at the top, and the
      // junk it shipped with sorts to the bottom where it's easy to untick.
      files.sort((a, b) => b.size.compareTo(a.size));
      if (mounted) setState(() => _files = files);
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e'.replaceAll('Exception: ', ''));
      }
    }
  }

  Future<void> _save() async {
    final files = _files;
    if (files == null) return;
    final keep = [
      for (final f in files)
        if (f.wanted) f.path,
    ];
    if (keep.isEmpty) {
      setState(() => _error = 'Keep at least one file.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(vaultClientProvider)
          .torrents
          .setFiles(widget.torrent.hash, keep);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e'.replaceAll('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final files = _files;
    final keptBytes = files == null
        ? 0
        : files.where((f) => f.wanted).fold<int>(0, (n, f) => n + f.size);

    return AlertDialog(
      title: const Text('Files in this torrent'),
      content: SizedBox(
        width: 520,
        child: files == null
            ? SizedBox(
                height: 120,
                child: Center(
                  child: _error != null
                      ? Text(_error!, style: TextStyle(color: scheme.error))
                      : const CircularProgressIndicator(),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: files.length,
                      itemBuilder: (context, i) {
                        final f = files[i];
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: f.wanted,
                          onChanged: _saving
                              ? null
                              : (v) => setState(
                                  () => files[i] = f.copyWith(wanted: v ?? false)),
                          title: Text(
                            f.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            [
                              formatBytes(f.size),
                              if (f.progress > 0 && f.progress < 1)
                                '${(f.progress * 100).toStringAsFixed(0)}%',
                              // Show the folder only when there is one, so a
                              // flat torrent isn't cluttered with "./".
                              if (f.path.contains('/'))
                                f.path.substring(0, f.path.lastIndexOf('/')),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11, color: scheme.onSurfaceVariant),
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(),
                  Text(
                    'Keeping ${formatBytes(keptBytes)} of '
                    '${formatBytes(widget.torrent.size)}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Unticked files are skipped when the download is imported. '
                    'qBittorrent is also asked not to fetch them, but the '
                    'server enforces this either way.',
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: TextStyle(color: scheme.error, fontSize: 12.5)),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || files == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}
