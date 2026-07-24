import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/capability/manifest_providers.dart';
import 'core/habits/habits.dart';
import 'core/prefs/theme_prefs.dart';
import 'core/platform/design/adaptive_icons.dart';
import 'core/services/service_registry.dart';
import 'features/files/file_actions.dart';
import 'features/files/files_page.dart';
import 'features/files/widgets/files_toolbar_leading.dart';
import 'core/jobs/job.dart';
import 'features/jobs/jobs_page.dart';
import 'features/media/media_library_page.dart';
import 'features/media/widgets/media_filter_dropdown.dart';
import 'features/media/widgets/music_section.dart';
import 'features/movies/movies_section.dart';
import 'features/placeholder_page.dart';
import 'features/settings/settings_page.dart';
import 'features/user/user_page.dart';
import 'features/photos/data/background_backup.dart';
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
    icon: VaultIcons.media,
    category: ServiceCategory.media,
    // Always available: the media browser reads THIS DEVICE's own photos and
    // videos — a local capability the server has no say over. So even a
    // connected member with no grants (or a standalone device) still gets a
    // working tab and never a blank bottom nav.
    alwaysAvailable: true,
    statusBar: (_) => const MediaToolbarControls(),
    builder: (_) => const MediaLibraryPage(),
  ),
  ServiceDefinition(
    id: 'files',
    label: 'My files',
    icon: VaultIcons.files,
    category: ServiceCategory.files,
    actions: filesServiceActions,
    toolbarLeading: (_) => const FilesToolbarLeading(),
    builder: (_) => const FilesPage(),
  ),
  ServiceDefinition(
    id: 'music',
    label: 'Music',
    icon: VaultIcons.music,
    category: ServiceCategory.media,
    actions: musicServiceActions,
    builder: (_) => const MusicSection(),
  ),
  ServiceDefinition(
    id: 'torrent',
    label: 'Torrent',
    icon: VaultIcons.torrent,
    category: ServiceCategory.tools,
    actions: torrentServiceActions,
    builder: (_) => const JobsPage(kind: JobKind.torrent),
  ),
  ServiceDefinition(
    id: 'downloads',
    label: 'Downloads',
    icon: VaultIcons.downloads,
    category: ServiceCategory.tools,
    actions: downloadsServiceActions,
    builder: (_) => const JobsPage(kind: JobKind.download),
  ),
  // Movies registers here (after the core dock services) so it never
  // displaces the established Media/Files/Music/Torrent dock pins; category
  // 'media' still groups it with music in the desktop sidebar, and the
  // server manifest decides who actually sees it (movies:read).
  ServiceDefinition(
    id: 'movies',
    label: 'Movies',
    icon: VaultIcons.playVideo,
    category: ServiceCategory.media,
    builder: (_) => const MoviesSection(),
  ),
  // NOTE: photo BACKUP is deliberately not a service tab — it's a property
  // of the media library: the cloud button in the Media toolbar opens the
  // backup sheet (features/photos). The `photos` grant still gates it.
  ServiceDefinition(
    id: 'chat',
    label: 'AI Chat',
    icon: VaultIcons.chat,
    category: ServiceCategory.tools,
    builder: (_) => const PlaceholderPage(
      title: 'AI Chat',
      icon: Icons.chat_bubble_outline,
    ),
  ),
  ServiceDefinition(
    id: 'settings',
    label: 'Settings',
    icon: VaultIcons.settings,
    category: ServiceCategory.system,
    alwaysAvailable: true, // never lock a user out of their own device
    builder: (_) => const SettingsPage(),
  ),
  ServiceDefinition(
    id: 'user',
    label: 'You',
    icon: VaultIcons.user,
    category: ServiceCategory.system,
    alwaysAvailable: true, // identity/devices must always be reachable
    actions: userServiceActions,
    builder: (_) => const UserPage(),
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
          onRetry: () => ref.read(manifestProvider.notifier).reload(),
        ),
      ),
    ];
  } else {
    // Landing tab: prefer the first real CONTENT service; fall back to the You
    // page, and never Settings. A zero-grant member's permitted set is only
    // the always-available services (settings, user) — and settings sorts
    // first, so without this they booted straight INTO the Settings screen
    // with no other tabs and looked stranded. Settings stays a branch (the
    // desktop sidebar lists it), it just can't be the home tab.
    const notLanding = {'settings', 'user'};
    final landing = services.firstWhere(
      (s) => !notLanding.contains(s.id),
      orElse: () => services.firstWhere(
        (s) => s.id == 'user',
        orElse: () => services.first,
      ),
    );

    // Habit-driven auto-land: if enabled and the person's most-used service is
    // permitted (and a real content tab), open THAT on cold start instead of
    // the default. Read (not watch) — this only steers the INITIAL location; we
    // don't want the router to rebuild when usage counts tick. Habits load from
    // prefs well before the manifest (a network fetch), so it's ready here.
    final habits = ref.read(habitsProvider).asData?.value;
    final topId = ref.read(topServiceIdProvider);
    final landOn =
        (habits?.autoLand ?? false) &&
            topId != null &&
            !notLanding.contains(topId) &&
            services.any((s) => s.id == topId)
        ? topId
        : landing.id;
    initialLocation = '/$landOn';
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
    final themeMode =
        ref.watch(themeModeProvider).asData?.value ?? ThemeMode.system;
    // Keep the OS background-backup schedule in lockstep with the auto-backup
    // preference — (re)arms on every launch (iOS needs re-arming) and reacts
    // to the toggle. No-op off mobile.
    ref.watch(backgroundBackupSchedulerProvider);
    return MaterialApp.router(
      title: 'Vault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3B6EA5),
        brightness: Brightness.light,
      ),
      darkTheme: _darkTheme(),
      themeMode: themeMode,
      routerConfig: router,
    );
  }

  /// True dark: Material's seeded dark scheme tints every surface toward the
  /// seed hue (the "why is dark mode blue" effect). Keep the seed for accents
  /// but pin all surfaces/containers to NEUTRAL near-blacks.
  ThemeData _darkTheme() {
    final seeded = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3B6EA5),
      brightness: Brightness.dark,
    );
    final scheme = seeded.copyWith(
      surface: const Color.fromARGB(255, 0, 0, 0),
      surfaceContainerLowest: const Color.fromARGB(255, 0, 0, 0),
      surfaceContainerLow: const Color.fromARGB(255, 0, 0, 0),
      surfaceContainer: const Color.fromARGB(255, 0, 0, 0),
      surfaceContainerHigh: const Color.fromARGB(255, 0, 0, 0),
      surfaceContainerHighest: const Color.fromARGB(255, 0, 0, 0),
      onSurface: const Color(0xFFE7E7EA),
      onSurfaceVariant: const Color(0xFFA6A6AE),
      outline: const Color(0xFF77777F),
      outlineVariant: const Color(0xFF2C2C30),
      inverseSurface: const Color(0xFFE7E7EA),
      surfaceTint: Colors.transparent, // no elevation tinting back to blue
    );
    return ThemeData(colorScheme: scheme, brightness: Brightness.dark);
  }
}
