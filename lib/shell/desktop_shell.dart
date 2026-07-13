import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/platform/platform_info.dart';
import '../core/services/service_registry.dart';
import 'widgets/app_title_bar.dart';

/// The sidebar (wide) layout, used by native desktop AND large tablets. The
/// difference: only native desktop draws the custom in-window title bar (menu
/// bar + traffic-light spacing + drag), because only there did we hide the OS
/// title bar. Tablets keep the OS status bar, so they get a slim, safe-area
/// header instead — no desktop menu chrome colliding with the status bar.
class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key, required this.shell, required this.services});

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nativeDesktop = isDesktopPlatform;

    final body = Column(
      children: [
        if (nativeDesktop) const AppTitleBar(),
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
    );

    return Scaffold(
      // Native desktop's title bar reserves its own space; tablets must clear
      // the OS status bar.
      body: nativeDesktop ? body : SafeArea(bottom: false, child: body),
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
