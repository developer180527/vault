import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/capability/capability.dart';
import '../../core/capability/manifest_providers.dart';
import '../../core/services/service_registry.dart';
import '../../core/tasks/background_tasks.dart';
import '../logs/log_viewer_page.dart';

/// Settings. In debug it doubles as the **mock manifest editor** — a stand-in
/// for the server's authoritative grants, so the capability-driven UI can be
/// exercised without a backend. In release this dev section is compiled out;
/// real grants arrive only from the server.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Account', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(child: Icon(Icons.person_outline)),
          title: Text('This device'),
          subtitle: Text('Profile & device identity — server-managed'),
        ),
        const Divider(height: 32),
        Text('Diagnostics', style: Theme.of(context).textTheme.titleSmall),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.article_outlined),
          title: const Text('View logs'),
          subtitle: const Text('Recent activity — useful for bug reports'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const LogViewerPage()),
          ),
        ),
        if (kDebugMode) ...[
          const Divider(height: 32),
          const _MockManifestEditor(),
          const Divider(height: 32),
          const _BackgroundTaskDemo(),
          const Divider(height: 32),
          const _CrashDemo(),
        ],
      ],
    );
  }
}

/// Simulates the server granting/revoking services and per-service actions.
class _MockManifestEditor extends ConsumerWidget {
  const _MockManifestEditor();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifest = ref.watch(mockManifestProvider);
    final services = ref.watch(serviceRegistryProvider);
    final notifier = ref.read(mockManifestProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Server grants (mock)',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Simulates your home server. Revoking a service hides its tab '
          'everywhere; actions gate controls inside a feature.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final s in services)
          _ServiceGrantTile(
            service: s,
            granted: manifest.has(s.id),
            actions: manifest.capabilities[s.id]?.actions ?? const {},
            onToggleService: (v) => notifier.setServiceGranted(s.id, v),
            onToggleAction: (a, v) => notifier.setAction(s.id, a, v),
          ),
      ],
    );
  }
}

class _ServiceGrantTile extends StatelessWidget {
  const _ServiceGrantTile({
    required this.service,
    required this.granted,
    required this.actions,
    required this.onToggleService,
    required this.onToggleAction,
  });

  final ServiceDefinition service;
  final bool granted;
  final Set<CapabilityAction> actions;
  final ValueChanged<bool> onToggleService;
  final void Function(CapabilityAction, bool) onToggleAction;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: Icon(service.icon),
      title: Text(service.label),
      subtitle: Text(service.alwaysAvailable
          ? 'Always available'
          : granted
              ? 'Granted'
              : 'Revoked'),
      trailing: Switch(
        value: granted,
        onChanged: service.alwaysAvailable ? null : onToggleService,
      ),
      children: [
        if (granted)
          Wrap(
            spacing: 6,
            children: [
              for (final a in CapabilityAction.values)
                FilterChip(
                  label: Text(a.name),
                  selected: actions.contains(a),
                  onSelected: (v) => onToggleAction(a, v),
                ),
            ],
          )
        else
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Grant the service to configure actions.'),
          ),
      ],
    );
  }
}

class _BackgroundTaskDemo extends ConsumerWidget {
  const _BackgroundTaskDemo();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(backgroundTasksProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Background tasks (demo)',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: () {
                final n = tasks.length + 1;
                ref.read(backgroundTasksProvider.notifier).upsert(
                      BackgroundTask(
                        id: 'demo-$n',
                        label: 'Uploading IMG_00$n.jpg',
                        progress: (n * 0.23) % 1.0,
                      ),
                    );
              },
              child: const Text('Add task'),
            ),
            OutlinedButton(
              onPressed: () =>
                  ref.read(backgroundTasksProvider.notifier).clear(),
              child: const Text('Clear'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Proves feature isolation: navigating into the crashing view shows a
/// contained error panel while the rest of the app keeps working.
class _CrashDemo extends StatelessWidget {
  const _CrashDemo();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Failure isolation (demo)',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.bug_report_outlined),
          label: const Text('Open a view that crashes'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Crashing view')),
                body: const _AlwaysThrows(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AlwaysThrows extends StatelessWidget {
  const _AlwaysThrows();

  @override
  Widget build(BuildContext context) {
    throw StateError('Simulated feature crash');
  }
}
