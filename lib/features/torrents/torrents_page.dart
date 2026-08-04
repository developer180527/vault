import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/client/http_torrents_api.dart' show TorrentsUnavailable;
import '../../core/client/vault_client.dart';
import '../../core/jobs/job.dart';
import '../../shell/widgets/server_unavailable.dart';
import '../admin/data/content_upload_engine.dart' show isAdminProvider;
import 'data/torrents.dart';
import 'widgets/torrent_tile.dart';

/// The Torrent service: a remote client for the household's qBittorrent.
///
/// Two ways in — a magnet link, or a .torrent file you already have — but both
/// run through the same job pipeline, which is what files the finished download
/// somewhere you can actually see it.
///
/// An admin also picks the DESTINATION up front: their own files, or straight
/// into the shared movie/music library. That last option matters because the
/// file is already on the server when qBittorrent finishes; without it, adding
/// a movie to the household catalog meant downloading those bytes to a laptop
/// and uploading the identical ones back.
class TorrentsPage extends ConsumerWidget {
  const TorrentsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final torrents = ref.watch(torrentListProvider);
    final canManage = ref.watch(canManageTorrentsProvider);

    return Column(
      children: [
        if (canManage) const _AddBar(),
        const _TransferBar(),
        const Divider(height: 1),
        Expanded(
          child: torrents.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => e is TorrentsUnavailable
                ? const _Notice(
                    icon: Icons.cloud_off_outlined,
                    title: 'Torrents are not set up',
                    detail:
                        'This server has no qBittorrent configured, so there '
                        'is nothing to manage yet.',
                  )
                : ServerUnavailable(
                    message: "Can't reach the torrent client",
                    detail: '$e',
                    onRetry: () async => ref.invalidate(torrentListProvider),
                  ),
            data: (list) => list.isEmpty
                ? const _Notice(
                    icon: Icons.downloading_outlined,
                    title: 'No torrents',
                    detail:
                        'Add a magnet link and the server downloads it into '
                        'your library, or add a .torrent file you already '
                        'have.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(top: 4, bottom: 120),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) =>
                        TorrentTile(torrent: list[i], canManage: canManage),
                  ),
          ),
        ),
      ],
    );
  }
}

class _AddBar extends ConsumerWidget {
  const _AddBar();

  Future<void> _addMagnet(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    var dest = JobDest.myFiles;
    final isAdmin = ref.read(isAdminProvider);

    final magnet = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Add magnet link'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                autocorrect: false,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  hintText: 'magnet:?xt=urn:btih:…',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
              ),
              const SizedBox(height: 14),
              _DestPicker(
                value: dest,
                isAdmin: isAdmin,
                onChanged: (d) => setLocal(() => dest = d),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (magnet == null || magnet.isEmpty) return;
    if (!magnet.startsWith('magnet:')) {
      if (context.mounted) {
        _toast(context, "That doesn't look like a magnet link.");
      }
      return;
    }
    try {
      // Magnets go through the JOB pipeline — that's what moves the finished
      // download into the library.
      await ref.read(vaultClientProvider).jobs.submit(
            JobRequest(kind: JobKind.torrent, source: magnet, dest: dest),
          );
      ref.invalidate(torrentListProvider);
    } catch (e) {
      if (context.mounted) _toast(context, 'Could not add: $e');
    }
  }

  Future<void> _addFile(BuildContext context, WidgetRef ref) async {
    final dest = await _askDest(context, ref);
    if (dest == null) return;
    // NO type filter. On Apple platforms file_selector matches by UTI, not by
    // extension, and there is no system UTI for .torrent — so an
    // extensions-based filter greys out every file and the picker looks
    // broken (the same trap the movie uploader hit with .mkv). The server
    // parses the bencode anyway and rejects anything that isn't a torrent,
    // so filtering here would only ever be cosmetic.
    final picked = await openFile();
    if (picked == null) return;
    try {
      final bytes = await File(picked.path).readAsBytes();
      await ref
          .read(vaultClientProvider)
          .torrents
          .addFile(picked.name, bytes, dest: dest);
      ref.invalidate(torrentListProvider);
    } catch (e) {
      if (context.mounted) {
        _toast(context, '$e'.replaceAll('Exception: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: () => _addMagnet(context, ref),
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Add magnet'),
          ),
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
            onPressed: () => _addFile(context, ref),
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: const Text('Add .torrent'),
          ),
          const Spacer(),
          const _LimitsButton(),
        ],
      ),
    );
  }
}

/// Live global throughput. Reads as a status line, not a control.
class _TransferBar extends ConsumerWidget {
  const _TransferBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(transferStatsProvider).asData?.value;
    if (stats == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);

    Widget rate(IconData icon, int speed, int limit) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 3),
            Text(
              speed <= 0 ? '—' : formatSpeed(speed),
              style: style,
            ),
            if (limit > 0)
              Text(' (limit ${formatSpeed(limit)})', style: style),
          ],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          rate(Icons.arrow_downward, stats.dlSpeed, stats.dlLimit),
          const SizedBox(width: 16),
          rate(Icons.arrow_upward, stats.upSpeed, stats.upLimit),
        ],
      ),
    );
  }
}

/// Global speed limits. Shown to everyone so the current limit is visible, but
/// the server refuses the change for non-admins — one household, one pipe.
class _LimitsButton extends ConsumerWidget {
  const _LimitsButton();

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final stats = ref.read(transferStatsProvider).asData?.value;
    // Limits are bytes/sec on the wire; people think in KB/s.
    final dl = TextEditingController(
        text: stats == null || stats.dlLimit == 0
            ? ''
            : '${stats.dlLimit ~/ 1024}');
    final up = TextEditingController(
        text: stats == null || stats.upLimit == 0
            ? ''
            : '${stats.upLimit ~/ 1024}');

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Speed limits'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: dl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Download limit (KB/s)',
                hintText: 'blank = unlimited',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: up,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Upload limit (KB/s)',
                hintText: 'blank = unlimited',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'These apply to the whole household — qBittorrent has one '
              'connection, shared by everyone.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    int parse(TextEditingController c) {
      final v = c.text.trim();
      if (v.isEmpty) return 0; // unlimited
      final kb = int.tryParse(v);
      return kb == null || kb < 0 ? 0 : kb * 1024;
    }

    try {
      await ref
          .read(vaultClientProvider)
          .torrents
          .setLimits(dlLimit: parse(dl), upLimit: parse(up));
      ref.invalidate(transferStatsProvider);
    } catch (e) {
      if (context.mounted) {
        _toast(context, '$e'.replaceAll('Exception: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: 'Speed limits',
      icon: const Icon(Icons.speed_outlined, size: 20),
      onPressed: () => _edit(context, ref),
    );
  }
}

/// Where a finished download should land.
///
/// Only shown with real choices — a member has exactly one destination, and a
/// picker with a single option is noise. The server enforces the same rule, so
/// hiding it here is convenience, not security.
class _DestPicker extends StatelessWidget {
  const _DestPicker({
    required this.value,
    required this.isAdmin,
    required this.onChanged,
  });

  final JobDest value;
  final bool isAdmin;
  final ValueChanged<JobDest> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!isAdmin) {
      return Text(
        'Lands in My files → downloads.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Save to', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        SegmentedButton<JobDest>(
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: [
            for (final d in JobDest.values)
              ButtonSegment(value: d, label: Text(d.label)),
          ],
          selected: {value},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        const SizedBox(height: 6),
        Text(
          value == JobDest.myFiles
              ? 'Private to you.'
              : 'Goes straight into the shared library when it finishes — no '
                  'need to download it and upload it again.',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Asks for a destination before picking a file. Members skip the prompt —
/// they have only one place it can go.
Future<JobDest?> _askDest(BuildContext context, WidgetRef ref) async {
  if (!ref.read(isAdminProvider)) return JobDest.myFiles;
  var dest = JobDest.myFiles;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('Add .torrent file'),
        content: _DestPicker(
          value: dest,
          isAdmin: true,
          onChanged: (d) => setLocal(() => dest = d),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Choose file…'),
          ),
        ],
      ),
    ),
  );
  return ok == true ? dest : null;
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.primary),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

void _toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
