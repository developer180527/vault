import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions/vault_action.dart';
import '../../core/capability/capability.dart';
import '../../core/capability/manifest_providers.dart';
import '../../core/client/vault_client.dart';
import '../../core/jobs/job.dart';
import '../../core/platform/design/adaptive_icons.dart';

/// Live job list from the client seam. StreamProvider so every view (both
/// tabs, future status chip) shares ONE subscription; each view filters by
/// kind.
final jobsProvider = StreamProvider<List<VaultJob>>(
    (ref) => ref.watch(vaultClientProvider).jobs.watch());

bool _can(WidgetRef ref, String service) =>
    ref.read(canProvider((serviceId: service, action: CapabilityAction.write)));

/// Actions for the Torrent service (magnets only).
final torrentServiceActions = <VaultAction>[
  VaultAction(
    id: 'torrent.add',
    label: 'Add torrent',
    icon: VaultIcons.addLink,
    isEnabled: (ref) => _can(ref, 'torrent'),
    onInvoke: (context, ref) => promptAdd(context, ref, JobKind.torrent),
  ),
  VaultAction(
    id: 'torrent.clear',
    label: 'Clear finished',
    icon: VaultIcons.clearFinished,
    onInvoke: (context, ref) =>
        ref.read(vaultClientProvider).jobs.clearFinished(),
  ),
];

/// Actions for the Downloads (yt-dlp) service (URLs only).
final downloadsServiceActions = <VaultAction>[
  VaultAction(
    id: 'downloads.add',
    label: 'Add download',
    icon: VaultIcons.addLink,
    isEnabled: (ref) => _can(ref, 'downloads'),
    onInvoke: (context, ref) => promptAdd(context, ref, JobKind.download),
  ),
  VaultAction(
    id: 'downloads.clear',
    label: 'Clear finished',
    icon: VaultIcons.clearFinished,
    onInvoke: (context, ref) =>
        ref.read(vaultClientProvider).jobs.clearFinished(),
  ),
];

/// Paste-a-link flow, specialized per kind: torrents take a magnet, downloads
/// take a video/media URL fetched with yt-dlp on the server.
Future<void> promptAdd(
    BuildContext context, WidgetRef ref, JobKind kind) async {
  final isTorrent = kind == JobKind.torrent;
  final controller = TextEditingController();
  final source = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(isTorrent ? 'Add torrent' : 'Add download'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: isTorrent ? 'Magnet link' : 'Video or media URL',
          helperText: isTorrent
              ? 'Paste a magnet link; qBittorrent downloads it to your library.'
              : 'Paste a URL; yt-dlp fetches it to your library.',
          helperMaxLines: 2,
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    ),
  );
  if (source == null || source.isEmpty) return;

  // Guard against pasting the wrong thing into the wrong tab.
  if (isTorrent && !source.startsWith('magnet:')) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That doesn\'t look like a magnet link')));
    }
    return;
  }
  final job = await ref
      .read(vaultClientProvider)
      .jobs
      .submit(JobRequest(kind: kind, source: source));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued "${job.title}"')));
  }
}

/// One job list, filtered to a single [kind] so Torrent and Downloads are
/// distinct tabs over the shared pipeline. The scheduler runs jobs
/// automatically — this view only submits and observes.
class JobsPage extends ConsumerWidget {
  const JobsPage({super.key, required this.kind});

  final JobKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(jobsProvider);
    return jobsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Jobs unavailable: $e')),
      data: (all) {
        final jobs = [for (final j in all) if (j.kind == kind) j];
        if (jobs.isEmpty) return _EmptyJobs(kind: kind);
        return ListView.builder(
          // Bottom inset so the last job scrolls clear of the floating dock
          // (the tab bar above already consumed the top inset).
          padding: EdgeInsets.only(
              top: 4, bottom: 12 + MediaQuery.paddingOf(context).bottom),
          itemCount: jobs.length,
          itemBuilder: (context, i) => _JobTile(job: jobs[i]),
        );
      },
    );
  }
}

class _EmptyJobs extends ConsumerWidget {
  const _EmptyJobs({required this.kind});

  final JobKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isTorrent = kind == JobKind.torrent;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveIcon(kind.icon, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text(isTorrent ? 'No torrents yet' : 'No downloads yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              isTorrent
                  ? 'Paste a magnet link and your server downloads it.'
                  : 'Paste a video or media URL and your server fetches it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.add_link),
              label: Text(isTorrent ? 'Add torrent' : 'Add download'),
              onPressed: () => promptAdd(context, ref, kind),
            ),
          ],
        ),
      ),
    );
  }
}

class _JobTile extends ConsumerWidget {
  const _JobTile({required this.job});

  final VaultJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final jobs = ref.read(vaultClientProvider).jobs;

    final (stateColor, stateIcon) = switch (job.state) {
      JobState.queued => (scheme.onSurfaceVariant, Icons.schedule),
      JobState.running => (scheme.primary, Icons.downloading),
      JobState.completed => (scheme.primary, Icons.check_circle_outline),
      JobState.failed => (scheme.error, Icons.error_outline),
      JobState.canceled => (scheme.onSurfaceVariant, Icons.cancel_outlined),
    };

    return ListTile(
      leading: AdaptiveIcon(job.kind.icon),
      title: Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (job.state == JobState.running ||
              job.state == JobState.queued) ...[
            const SizedBox(height: 6),
            // Always a determinate value: the indeterminate variant runs an
            // endless animation, burning frames while queued jobs just wait.
            LinearProgressIndicator(
              value: job.state == JobState.queued ? 0 : job.progress,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 4),
          ],
          Row(
            children: [
              Icon(stateIcon, size: 14, color: stateColor),
              const SizedBox(width: 4),
              Text(
                job.state == JobState.running
                    ? '${(job.progress * 100).round()}% · ${job.kind.label}'
                    : (job.message ?? '${job.state.label} · ${job.kind.label}'),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: stateColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ],
      ),
      trailing: switch (job.state) {
        JobState.queued || JobState.running => IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: () => jobs.cancel(job.id),
          ),
        JobState.failed || JobState.canceled => IconButton(
            tooltip: 'Retry',
            icon: const Icon(Icons.refresh),
            onPressed: () => jobs.retry(job.id),
          ),
        JobState.completed => null,
      },
    );
  }
}
