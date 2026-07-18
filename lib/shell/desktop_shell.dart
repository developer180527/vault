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
    // Desktop power preferences: dock edge + collapsed state.
    final sidebarRight = ref.watch(sidebarPositionProvider).asData?.value ==
        SidebarPosition.right;
    final hidden = ref.watch(sidebarHiddenProvider).asData?.value ?? false;

    final sidebar = _Sidebar(shell: shell, services: services);
    final divider =
        VerticalDivider(width: 1, thickness: 1, color: theme.dividerColor);
    final content = Expanded(
      child: Stack(
        children: [
          Positioned.fill(child: shell),
          // While collapsed, a floating reveal button keeps the sidebar one
          // click away (the title-bar toggle also works on native desktop).
          if (hidden)
            Positioned(
              top: 8,
              left: sidebarRight ? null : 8,
              right: sidebarRight ? 8 : null,
              child: Material(
                color: theme.colorScheme.surfaceContainerHigh,
                shape: const CircleBorder(),
                elevation: 2,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () =>
                      ref.read(sidebarHiddenProvider.notifier).toggle(),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Tooltip(
                      message: 'Show sidebar',
                      child: Icon(Icons.menu_open, size: 18),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final body = Column(
      children: [
        if (nativeDesktop) const AppTitleBar(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: hidden
                ? [content]
                : sidebarRight
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

  /// One flat list of services (no category headers — they were visual noise
  /// at family scale), honoring the user's pins from the You page: a service
  /// is listed when it's pinned, always-available (Settings, You), or
  /// currently active (so unpinning the page you're on doesn't strand you).
  /// Everything else launches from the You page shelf. Branch index is the
  /// service's position in [services].
  Widget _buildList(BuildContext context, List<String> pinnedIds) {
    bool visible(int i, ServiceDefinition s) =>
        pinnedIds.contains(s.id) ||
        s.alwaysAvailable ||
        i == shell.currentIndex;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        for (var i = 0; i < services.length; i++)
          if (visible(i, services[i]))
            _SidebarItem(
              service: services[i],
              selected: shell.currentIndex == i,
              onTap: () =>
                  shell.goBranch(i, initialLocation: i == shell.currentIndex),
            ),
      ],
    );
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
          // Collapse control, right-aligned above the list.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Hide sidebar',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.menu_open, size: 18),
                  onPressed: () =>
                      ref.read(sidebarHiddenProvider.notifier).toggle(),
                ),
              ],
            ),
          ),
          Expanded(child: _buildList(context, pinnedIds)),
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
