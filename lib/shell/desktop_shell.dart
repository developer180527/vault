import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/services/service_registry.dart';
import 'widgets/app_title_bar.dart';

/// Desktop layout matching the design: a full-width custom title bar (in-window
/// menu bar + task status) across the top, then a permanent service sidebar on
/// the left and the content pane on the right. The content pane has its own
/// toolbar with back/forward navigation; feature pages add controls (like the
/// sub-tab selector) into it.
class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key, required this.shell, required this.services});

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          const AppTitleBar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Sidebar(shell: shell, services: services),
                VerticalDivider(
                    width: 1, thickness: 1, color: theme.dividerColor),
                Expanded(child: shell),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.shell, required this.services});

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;

  /// Sidebar entries grouped by category. Headers appear only when more than
  /// one category is present, so a small install stays clean; a large one stays
  /// organized. Branch index is the service's position in [services].
  Widget _buildGroupedList(BuildContext context) {
    final theme = Theme.of(context);
    final categoriesPresent =
        services.map((s) => s.category).toSet().length > 1;

    final children = <Widget>[];
    for (final category in ServiceCategory.values) {
      final inCategory = [
        for (var i = 0; i < services.length; i++)
          if (services[i].category == category) (i, services[i]),
      ];
      if (inCategory.isEmpty) continue;
      if (categoriesPresent) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
          child: Text(category.label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ));
      }
      for (final (i, service) in inCategory) {
        children.add(_SidebarItem(
          service: service,
          selected: shell.currentIndex == i,
          onTap: () =>
              shell.goBranch(i, initialLocation: i == shell.currentIndex),
        ));
      }
    }
    return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 8), children: children);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 220,
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Expanded(child: _buildGroupedList(context)),
          Divider(height: 1, color: theme.dividerColor),
          Padding(
            padding: const EdgeInsets.all(8),
            child: _SidebarItem(
              service: ServiceDefinition(
                id: 'trash',
                label: 'Trash',
                icon: Icons.delete_outline,
                selectedIcon: Icons.delete,
                builder: (_) => const SizedBox.shrink(),
              ),
              selected: false,
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Trash — coming with sync'))),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem(
      {required this.service, required this.selected, required this.onTap});

  final ServiceDefinition service;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(selected ? service.selectedIcon : service.icon, size: 20),
                const SizedBox(width: 12),
                Text(service.label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
