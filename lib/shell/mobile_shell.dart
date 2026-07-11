import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/prefs/pinned_services.dart';
import '../core/services/service_registry.dart';
import 'services_hub_page.dart';
import 'widgets/task_status_button.dart';

/// Max destinations in a Material bottom bar. When there are more permitted
/// services than this, the last slot becomes "More" (opening the Services hub)
/// and the first [_kMaxBar]-1 come from the user's pinned list.
const _kMaxBar = 5;

/// Mobile layout. Navigation scales past a handful of services by pinning: the
/// bottom bar shows a customizable subset, and everything else lives in a
/// searchable Services hub reached via "More".
class MobileShell extends ConsumerWidget {
  const MobileShell({super.key, required this.shell, required this.services});

  final StatefulNavigationShell shell;

  /// Permitted services (already manifest-filtered), in registry order. Their
  /// position here *is* their shell branch index.
  final List<ServiceDefinition> services;

  int _branchIndexOf(String serviceId) =>
      services.indexWhere((s) => s.id == serviceId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinnedIds = ref.watch(pinnedServicesProvider).asData?.value ?? const [];
    final needsHub = services.length > _kMaxBar;

    // Bar services: when everything fits, show them all. Otherwise show the
    // user's pinned services (that are still permitted), backfilled from
    // registry order, capped to leave room for "More".
    late final List<ServiceDefinition> barServices;
    if (!needsHub) {
      barServices = services;
    } else {
      final pinned = [
        for (final id in pinnedIds)
          if (_branchIndexOf(id) >= 0) services[_branchIndexOf(id)],
      ];
      final backfill = [
        for (final s in services)
          if (!pinned.contains(s)) s,
      ];
      barServices = [...pinned, ...backfill].take(_kMaxBar - 1).toList();
    }

    final currentServiceId = services[shell.currentIndex].id;
    final selectedBarIndex =
        barServices.indexWhere((s) => s.id == currentServiceId);
    // If the active service isn't in the bar, highlight "More".
    final navSelectedIndex =
        selectedBarIndex >= 0 ? selectedBarIndex : barServices.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(services[shell.currentIndex].label),
        actions: const [TaskStatusButton(), SizedBox(width: 4)],
      ),
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navSelectedIndex,
        onDestinationSelected: (index) {
          if (index < barServices.length) {
            final target = _branchIndexOf(barServices[index].id);
            shell.goBranch(target, initialLocation: target == shell.currentIndex);
          } else {
            _openHub(context);
          }
        },
        destinations: [
          for (final s in barServices)
            NavigationDestination(
              icon: Icon(s.icon),
              selectedIcon: Icon(s.selectedIcon),
              label: s.label,
            ),
          if (needsHub)
            const NavigationDestination(
              icon: Icon(Icons.apps),
              selectedIcon: Icon(Icons.apps),
              label: 'More',
            ),
        ],
      ),
    );
  }

  void _openHub(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ServicesHubPage(
        services: services,
        onOpen: (serviceId) {
          Navigator.of(context).pop();
          final target = _branchIndexOf(serviceId);
          if (target >= 0) shell.goBranch(target);
        },
      ),
    ));
  }
}
