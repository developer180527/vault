import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/capability/manifest_providers.dart';
import 'core/services/service_registry.dart';
import 'features/media/media_library_page.dart';
import 'features/placeholder_page.dart';
import 'features/settings/settings_page.dart';
import 'shell/adaptive_shell.dart';
import 'shell/service_page.dart';
import 'shell/widgets/boot_screens.dart';

/// The service catalog: UI/route declarations only. Visibility is decided by
/// the server capability manifest, never here. Adding a service to Vault = one
/// entry here; the server grants who sees it. `category` drives grouping in the
/// desktop sidebar and mobile Services hub.
final vaultServices = <ServiceDefinition>[
  ServiceDefinition(
    id: 'media',
    label: 'Media',
    icon: Icons.tv_outlined,
    selectedIcon: Icons.tv,
    category: ServiceCategory.media,
    builder: (_) => const MediaLibraryPage(),
  ),
  ServiceDefinition(
    id: 'files',
    label: 'My files',
    icon: Icons.description_outlined,
    selectedIcon: Icons.description,
    category: ServiceCategory.files,
    builder: (_) => const PlaceholderPage(
        title: 'My files', icon: Icons.description_outlined),
  ),
  ServiceDefinition(
    id: 'torrent',
    label: 'Torrent',
    icon: Icons.public_outlined,
    selectedIcon: Icons.public,
    category: ServiceCategory.tools,
    subTabs: [
      SubTab(
        id: 'downloads',
        label: 'Downloads',
        icon: Icons.download_outlined,
        builder: (_) => const PlaceholderPage(
            title: 'Downloads', icon: Icons.download_outlined),
      ),
      SubTab(
        id: 'search',
        label: 'Search',
        icon: Icons.search,
        builder: (_) =>
            const PlaceholderPage(title: 'Search', icon: Icons.search),
      ),
    ],
  ),
  ServiceDefinition(
    id: 'chat',
    label: 'AI Chat',
    icon: Icons.chat_bubble_outline,
    selectedIcon: Icons.chat_bubble,
    category: ServiceCategory.tools,
    builder: (_) => const PlaceholderPage(
        title: 'AI Chat', icon: Icons.chat_bubble_outline),
  ),
  ServiceDefinition(
    id: 'settings',
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    category: ServiceCategory.system,
    alwaysAvailable: true, // never lock a user out of their own device
    builder: (_) => const SettingsPage(),
  ),
];

/// Router derived from the *manifest state*: while the manifest loads we show a
/// splash; if it fails we fail closed with a retry (never assume access); on
/// success we build one stateful branch per permitted service so each keeps its
/// own navigation stack. Rebuilt when grants change (a rare event).
final routerProvider = Provider<GoRouter>((ref) {
  final manifest = ref.watch(manifestProvider);
  final services = ref.watch(permittedServicesProvider);

  final List<RouteBase> routes;
  final String initialLocation;

  if (manifest.isLoading || services.isEmpty && !manifest.hasError) {
    initialLocation = '/_boot';
    routes = [GoRoute(path: '/_boot', builder: (_, _) => const SplashScreen())];
  } else if (manifest.hasError) {
    initialLocation = '/_boot';
    routes = [
      GoRoute(
          path: '/_boot',
          builder: (_, _) => ManifestErrorScreen(
                error: manifest.error!,
                onRetry: () =>
                    ref.read(manifestProvider.notifier).reload(),
              )),
    ];
  } else {
    initialLocation = '/${services.first.id}';
    routes = [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) =>
            AdaptiveShell(shell: shell, services: services),
        branches: [
          for (final s in services)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/${s.id}',
                  builder: (context, state) => ServicePage(service: s),
                ),
              ],
            ),
        ],
      ),
    ];
  }

  return GoRouter(initialLocation: initialLocation, routes: routes);
});

class VaultApp extends ConsumerWidget {
  const VaultApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Vault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3B6EA5),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF3B6EA5),
        brightness: Brightness.dark,
      ),
      routerConfig: router,
    );
  }
}
