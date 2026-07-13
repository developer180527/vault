import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions/vault_action.dart';
import '../../core/capability/capability.dart';
import '../../core/capability/manifest_providers.dart';
import '../../core/client/vault_client.dart';
import '../../core/jobs/job.dart';

/// Live job list from the client seam. StreamProvider so every view (tab,
/// future status chip) shares one subscription.
final jobsProvider = StreamProvider<List<VaultJob>>(
    (ref) => ref.watch(vaultClientProvider).jobs.watch());

bool _canSubmit(WidgetRef ref) => ref
    .read(canProvider((serviceId: 'torrent', action: CapabilityAction.write)));

/// Toolbar/palette actions for the Torrent service.
final torrentServiceActions = <VaultAction>[
  VaultAction(
    id: 'jobs.add',
    label: 'Add download',
    icon: Icons.add_link,
    isEnabled: _canSubmit,
    onInvoke: (context, ref) => promptAddDownload(context, ref),
  ),
  VaultAction(
    id: 'jobs.clear-finished',
    label: 'Clear finished',
    icon: Icons.clear_all,
    onInvoke: (context, ref) =>
        ref.read(vaultClientProvider).jobs.clearFinished(),
  ),
];

/// Paste-a-link flow: magnet links start a torrent job, anything else is
/// fetched server-side (yt-dlp style). The job system schedules it from there.
Future<void> promptAddDownload(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final source = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Add download'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Magnet link or URL',
          helperText: 'Magnet links download as torrents; any other URL is\n'
              'fetched with yt-dlp on your server.',
          helperMaxLines: 2,
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = controller.text.trim();
            Navigator.of(context).pop(v.isEmpty ? null : v);
          },
          child: const Text('Add'),
        ),
      ],
    ),
  );
  if (source == null || source.isEmpty) return;

  final kind =
      source.startsWith('magnet:') ? JobKind.torrent : JobKind.download;
  final job = await ref
      .read(vaultClientProvider)
      .jobs
      .submit(JobRequest(kind: kind, source: source));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued "${job.title}"')));
  }
}

/// The Downloads tab: every background job with live progress. The scheduler
/// runs jobs automatically — this view only submits and observes.
class JobsPage extends ConsumerWidget {
  const JobsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(jobsProvider);
    return jobsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Jobs unavailable: $e')),
      data: (jobs) => jobs.isEmpty
          ? const _EmptyJobs()
          : ListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 96),
              itemCount: jobs.length,
              itemBuilder: (context, i) => _JobTile(job: jobs[i]),
            ),
    );
  }
}

class _EmptyJobs extends ConsumerWidget {
  const _EmptyJobs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text('No downloads yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Paste a magnet link or URL and your server does the rest.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.add_link),
              label: const Text('Add download'),
              onPressed: () => promptAddDownload(context, ref),
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
      leading: Icon(job.kind.icon),
      title: Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (job.state == JobState.running ||
              job.state == JobState.queued) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: job.state == JobState.queued ? null : job.progress,
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
