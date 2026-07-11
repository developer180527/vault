import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/prefs/pinned_services.dart';
import '../core/services/service_registry.dart';

/// Full-screen launcher for every permitted service — the answer to "what
/// happens at 8-9+ services." Reached from the mobile bottom bar's "More".
/// Searchable, grouped by category, and lets the user pin services to the bar.
class ServicesHubPage extends ConsumerStatefulWidget {
  const ServicesHubPage({
    super.key,
    required this.services,
    required this.onOpen,
  });

  final List<ServiceDefinition> services;

  /// Called with the chosen service id; the shell navigates to its branch.
  final void Function(String serviceId) onOpen;

  @override
  ConsumerState<ServicesHubPage> createState() => _ServicesHubPageState();
}

class _ServicesHubPageState extends ConsumerState<ServicesHubPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final pinned = ref.watch(pinnedServicesProvider).asData?.value ?? const [];
    final q = _query.trim().toLowerCase();
    final matches = [
      for (final s in widget.services)
        if (q.isEmpty || s.label.toLowerCase().contains(q)) s,
    ];

    // Group matches by category, preserving registry order within each.
    final byCategory = <ServiceCategory, List<ServiceDefinition>>{};
    for (final s in matches) {
      byCategory.putIfAbsent(s.category, () => []).add(s);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Services'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SearchBar(
              hintText: 'Search services',
              leading: const Icon(Icons.search),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          for (final category in ServiceCategory.values)
            if (byCategory[category]?.isNotEmpty ?? false) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(category.label,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: Theme.of(context).colorScheme.primary)),
              ),
              for (final s in byCategory[category]!)
                _HubTile(
                  service: s,
                  pinned: pinned.contains(s.id),
                  onOpen: () => widget.onOpen(s.id),
                  onTogglePin: () =>
                      ref.read(pinnedServicesProvider.notifier).toggle(s.id),
                ),
            ],
        ],
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  const _HubTile({
    required this.service,
    required this.pinned,
    required this.onOpen,
    required this.onTogglePin,
  });

  final ServiceDefinition service;
  final bool pinned;
  final VoidCallback onOpen;
  final VoidCallback onTogglePin;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(service.icon),
      title: Text(service.label),
      trailing: IconButton(
        tooltip: pinned ? 'Unpin from bar' : 'Pin to bar',
        icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
        onPressed: onTogglePin,
      ),
      onTap: onOpen,
    );
  }
}
