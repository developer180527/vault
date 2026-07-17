import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/platform/design/adaptive_icons.dart';
import '../core/platform/platform_info.dart';
import '../core/prefs/desktop_prefs.dart';
import '../core/prefs/pinned_services.dart';
import '../core/services/service_registry.dart';
import 'widgets/app_title_bar.dart';
import 'widgets/now_playing_strip.dart';

/// The sidebar (wide) layout, used by native desktop AND large tablets. The
/// difference: only native desktop draws the custom in-window title bar (menu
/// bar + traffic-light spacing + drag), because only there did we hide the OS
/// title bar. Tablets keep the OS status bar, so they get a slim, safe-area
/// header instead — no desktop menu chrome colliding with the status bar.
class DesktopShell extends ConsumerWidget {
  const DesktopShell({super.key, required this.shell, required this.services});

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final nativeDesktop = isDesktopPlatform;
    // Desktop power preference: dock the sidebar to either edge.
    final sidebarRight = ref.watch(sidebarPositionProvider).asData?.value ==
        SidebarPosition.right;

    final sidebar = _Sidebar(shell: shell, services: services);
    final divider =
        VerticalDivider(width: 1, thickness: 1, color: theme.dividerColor);
    final content = Expanded(child: shell);

    final body = Column(
      children: [
        if (nativeDesktop) const AppTitleBar(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: sidebarRight
                ? [content, divider, sidebar]
                : [sidebar, divider, content],
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

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.shell, required this.services});

  final StatefulNavigationShell shell;
  final List<ServiceDefinition> services;

  /// Sidebar entries grouped by category, honoring the user's pins from the
  /// You page: a service is listed when it's pinned, always-available
  /// (Settings, You), or currently active (so unpinning the page you're on
  /// doesn't strand you). Everything else launches from the You page shelf.
  /// Headers appear only when more than one category is present, so a small
  /// install stays clean; a large one stays organized. Branch index is the
  /// service's position in [services].
  Widget _buildGroupedList(BuildContext context, List<String> pinnedIds) {
    final theme = Theme.of(context);
    bool visible(int i, ServiceDefinition s) =>
        pinnedIds.contains(s.id) ||
        s.alwaysAvailable ||
        i == shell.currentIndex;
    final categoriesPresent = {
      for (var i = 0; i < services.length; i++)
        if (visible(i, services[i])) services[i].category,
    }.length > 1;

    final children = <Widget>[];
    for (final category in ServiceCategory.values) {
      final inCategory = [
        for (var i = 0; i < services.length; i++)
          if (services[i].category == category && visible(i, services[i]))
            (i, services[i]),
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
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pinnedIds =
        ref.watch(pinnedServicesProvider).asData?.value ?? const <String>[];
    return Container(
      width: 220,
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Expanded(child: _buildGroupedList(context, pinnedIds)),
          // Tablets have no title bar, so the global now-playing control lives
          // here; native desktop shows it centered in the title bar instead.
          if (!isDesktopPlatform)
            const Padding(
              padding: EdgeInsets.all(8),
              child: NowPlayingStrip(maxTitleWidth: 96),
            ),
          Divider(height: 1, color: theme.dividerColor),
          Padding(
            padding: const EdgeInsets.all(8),
            child: _SidebarItem(
              service: ServiceDefinition(
                id: 'trash',
                label: 'Trash',
                icon: VaultIcons.trash,
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
                AdaptiveIcon(service.icon, selected: selected, size: 20),
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
