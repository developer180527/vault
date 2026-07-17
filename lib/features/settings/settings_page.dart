import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/capability/capability.dart';
import '../../core/version/build_info.dart';
import '../../core/capability/manifest_providers.dart';
import '../../core/platform/design/adaptive_icons.dart';
import '../../core/platform/platform_info.dart';
import '../../core/prefs/desktop_prefs.dart';
import '../../core/prefs/theme_prefs.dart';
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
      // Include the bottom safe-area inset so the last row clears the iOS home
      // indicator / bottom nav on release builds.
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
      children: [
        const _SectionHeader('Appearance'),
        const _AppearanceSection(),
        // Desktop-only power options. The platforms diverge on purpose: a
        // desktop app carries window/layout controls a phone never needs, so
        // this section simply doesn't exist on mobile builds.
        if (isDesktopPlatform) ...[
          const Divider(height: 32),
          const _SectionHeader('Desktop'),
          const _DesktopSection(),
        ],
        const Divider(height: 32),
        const _SectionHeader('Storage'),
        const _StorageSection(),
        const Divider(height: 32),
        const _SectionHeader('Account'),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(child: Icon(Icons.person_outline)),
          title: Text('This device'),
          subtitle: Text('Profile & device identity — server-managed'),
        ),
        const Divider(height: 32),
        const _SectionHeader('Diagnostics'),
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
        const Divider(height: 32),
        const _SectionHeader('About'),
        const _AboutTile(),
        if (kDebugMode) ...[
          const Divider(height: 32),
          const _SectionHeader('Developer'),
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

/// Desktop-only options (window/layout ergonomics that don't exist on mobile).
class _DesktopSection extends ConsumerWidget {
  const _DesktopSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(sidebarPositionProvider).asData?.value ??
        SidebarPosition.left;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(child: Text('Sidebar position')),
          SegmentedButton<SidebarPosition>(
            segments: const [
              ButtonSegment(
                  value: SidebarPosition.left,
                  icon: Icon(Icons.align_horizontal_left),
                  label: Text('Left')),
              ButtonSegment(
                  value: SidebarPosition.right,
                  icon: Icon(Icons.align_horizontal_right),
                  label: Text('Right')),
            ],
            selected: {position},
            onSelectionChanged: (s) =>
                ref.read(sidebarPositionProvider.notifier).set(s.first),
          ),
        ],
      ),
    );
  }
}

/// About tile: shows the app version + build; tapping opens the commit this
/// build was made from (baked in by tool/gen_build_info.sh).
class _AboutTile extends StatelessWidget {
  const _AboutTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.info_outline),
      title: const Text('Vault'),
      subtitle: Text(BuildInfo.label),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Vault'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(context, 'Version', BuildInfo.label),
              _row(context, 'Commit', BuildInfo.commit),
              _row(context, 'Built', BuildInfo.date),
              const SizedBox(height: 12),
              Text(BuildInfo.commitSubject,
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(
                    text:
                        '${BuildInfo.label} · ${BuildInfo.commit}\n${BuildInfo.commitSubject}'));
                Navigator.of(context).pop();
              },
              child: const Text('Copy'),
            ),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
                width: 72,
                child: Text(label,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant))),
            Expanded(child: Text(value)),
          ],
        ),
      );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// Theme picker (System / Light / Dark), persisted.
class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider).asData?.value ?? ThemeMode.system;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto_outlined),
              label: Text('System')),
          ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_outlined),
              label: Text('Light')),
          ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_outlined),
              label: Text('Dark')),
        ],
        selected: {mode},
        onSelectionChanged: (s) =>
            ref.read(themeModeProvider.notifier).set(s.first),
      ),
    );
  }
}

/// Shows the in-memory image cache footprint and lets the user clear cached
/// thumbnails/media — a real lever now that the grid caches aggressively.
class _StorageSection extends StatefulWidget {
  const _StorageSection();

  @override
  State<_StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends State<_StorageSection> {
  ImageCache get _cache => PaintingBinding.instance.imageCache;

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var size = bytes / 1024;
    var i = 0;
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${units[i]}';
  }

  Future<void> _clear() async {
    _cache.clear();
    _cache.clearLiveImages();
    await PhotoManager.clearFileCache();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cache cleared')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.sd_storage_outlined),
          title: const Text('Image cache'),
          subtitle: Text(
              '${_fmtBytes(_cache.currentSizeBytes)} · ${_cache.currentSize} images'),
          trailing: TextButton(
            onPressed: _clear,
            child: const Text('Clear'),
          ),
        ),
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
      leading: AdaptiveIcon(service.icon),
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
