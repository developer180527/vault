import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions/vault_action.dart';
import '../../core/client/vault_client.dart';
import '../../core/auth/local_auth_gate.dart';
import '../../core/auth/session.dart';
import '../../core/capability/manifest_providers.dart';
import '../../core/jobs/job.dart';
import '../../core/platform/design/adaptive_icons.dart';
import '../../core/platform/haptics.dart';
import '../../core/prefs/pinned_services.dart';
import '../../core/services/service_registry.dart';
import '../../shell/adaptive_shell.dart';
import '../../shell/service_page.dart';
import '../../shell/widgets/action_bar.dart';
import '../jobs/jobs_page.dart';
import '../media/widgets/media_trash_sheet.dart';
import '../settings/settings_page.dart';
import 'connect_flow.dart';

/// Services that never appear on the You page's shelf: You itself, and
/// Settings (reached via the gear in the top-right instead).
const _shelfExcluded = {'user', 'settings'};

/// Actions the You service contributes to the shell app bar — the Settings
/// gear in the top-right. Settings opens full-screen over the shell, so the
/// dock disappears while it's up.
final userServiceActions = <VaultAction>[
  VaultAction(
    id: 'user.settings',
    label: 'Settings',
    icon: VaultIcons.settings,
    onInvoke: (context, ref) {
      Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: const SettingsPage(),
        ),
      ));
    },
  ),
];

/// The You page: a FIXED identity header (picture, name, connect/disconnect)
/// that stays put, and below it three swipeable sections — **Services** (the
/// shelf), **Activity** (background jobs), **Trash** (media recently-deleted,
/// biometric-unlocked). Only the section content swipes; the header doesn't.
class UserPage extends ConsumerWidget {
  const UserPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // Fixed above the tabs — swiping the sections never moves this.
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: _ProfileHeader(),
          ),
          Expanded(
            child: DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  TabBar(
                    dividerColor: Colors.transparent,
                    indicatorSize: TabBarIndicatorSize.label,
                    labelColor: scheme.primary,
                    unselectedLabelColor: scheme.onSurfaceVariant,
                    tabs: const [
                      Tab(height: 44, icon: Icon(Icons.apps_outlined, size: 20)),
                      Tab(height: 44, icon: Icon(Icons.history, size: 20)),
                      Tab(
                          height: 44,
                          icon: Icon(Icons.delete_outline, size: 20)),
                    ],
                  ),
                  const Expanded(
                    child: TabBarView(
                      children: [
                        _ServicesSection(),
                        _ActivitySection(),
                        _TrashSection(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Services: the launch/pin shelf (the identity header lives fixed above).
class _ServicesSection extends ConsumerWidget {
  const _ServicesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(permittedServicesProvider);
    final pinnedIds =
        ref.watch(pinnedServicesProvider).asData?.value ?? const <String>[];
    final shelf = [
      for (final s in services)
        if (!_shelfExcluded.contains(s.id)) s,
    ];

    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 8, 16, 16 + MediaQuery.paddingOf(context).bottom),
      children: [
        if (shelf.isEmpty)
          // A freshly-invited member has no grants yet — say so plainly
          // instead of showing a blank shelf that reads as "broken".
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                Icon(Icons.lock_outline,
                    size: 40,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text('No services yet',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  'Your account is connected, but the admin hasn’t granted '
                  'you access to any services yet. Ask them to add you.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          )
        else
          for (final s in shelf)
            _ServiceTile(
              service: s,
              pinned: pinnedIds.contains(s.id),
              // Only currently-dockable services count toward the cap, so a
              // pin for a not-yet-permitted service can't wedge the dock.
              dockableIds: {for (final d in shelf) d.id},
            ),
      ],
    );
  }
}

/// Activity: this device's background jobs, newest first — a read-only feed
/// (manage them in the Torrent/Downloads tabs).
class _ActivitySection extends ConsumerWidget {
  const _ActivitySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final jobsAsync = ref.watch(jobsProvider);
    return jobsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Activity unavailable: $e')),
      data: (jobs) => jobs.isEmpty
          ? Center(
              child: Text('No activity yet.',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          : ListView.builder(
              padding: EdgeInsets.only(
                  bottom: 16 + MediaQuery.paddingOf(context).bottom),
              itemCount: jobs.length,
              itemBuilder: (context, i) {
                final j = jobs[i];
                return ListTile(
                  leading: AdaptiveIcon(j.kind.icon, size: 22),
                  title: Text(j.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    j.state == JobState.running
                        ? '${j.kind.label} · ${(j.progress * 100).round()}%'
                        : '${j.kind.label} · ${j.state.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: j.state == JobState.running
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, value: j.progress),
                        )
                      : null,
                );
              },
            ),
    );
  }
}

/// Trash: the media recently-deleted list, behind the device-local auth gate.
class _TrashSection extends ConsumerStatefulWidget {
  const _TrashSection();

  @override
  ConsumerState<_TrashSection> createState() => _TrashSectionState();
}

class _TrashSectionState extends ConsumerState<_TrashSection> {
  bool _unlocked = false;

  Future<void> _unlock() async {
    final ok = await ref
        .read(localAuthGateProvider)
        .authenticate(reason: 'Unlock the media trash');
    if (ok && mounted) setState(() => _unlocked = true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_unlocked) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Recently deleted is locked',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text("They'll be permanently deleted after 30 days.",
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.fingerprint),
              label: const Text('Unlock'),
              onPressed: _unlock,
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text("They'll be permanently deleted after 30 days.",
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ),
        const Expanded(child: MediaTrashList()),
      ],
    );
  }
}

/// The caller's profile picture bytes (null = none). Invalidated on upload.
final myAvatarProvider = FutureProvider<Uint8List?>((ref) {
  if (ref.watch(sessionProvider).asData?.value == null) return null;
  return ref.watch(vaultClientProvider).myAvatar();
});

class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader();

  Future<void> _pickAvatar(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final raw = picked?.files.single.bytes;
    if (raw == null) return;
    // Normalize before upload: iOS photos are usually HEIC (which the server's
    // content sniff rejects) and often several MB (over the size cap). Decode
    // via the platform codecs (handles HEIC), downscale, and re-encode as PNG
    // — a small, universally-recognized image that always passes.
    final bytes = await _normalizeAvatar(raw);
    if (bytes == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('That image could not be read.')));
      }
      return;
    }
    try {
      await ref.read(vaultClientProvider).setMyAvatar(bytes);
      ref.invalidate(myAvatarProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not set picture: $e')));
      }
    }
  }

  /// Decode (any format the platform supports, incl. HEIC), downscale to a
  /// 512px-wide avatar, and re-encode as PNG. Returns null if undecodable.
  Future<Uint8List?> _normalizeAvatar(Uint8List raw) async {
    try {
      final codec = await ui.instantiateImageCodec(raw, targetWidth: 512);
      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final session = ref.watch(sessionProvider).asData?.value;
    final connected = session != null;
    final avatar = ref.watch(myAvatarProvider).asData?.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            // Tap to set/change the picture (connected only — it lives on
            // the server, next to your identity).
            InkWell(
              customBorder: const CircleBorder(),
              onTap: connected ? () => _pickAvatar(context, ref) : null,
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: connected
                        ? scheme.primaryContainer
                        : scheme.secondaryContainer,
                    foregroundImage:
                        avatar != null ? MemoryImage(avatar) : null,
                    child: Icon(
                        connected ? Icons.person : Icons.person_outline,
                        size: 36,
                        color: connected
                            ? scheme.onPrimaryContainer
                            : scheme.onSecondaryContainer),
                  ),
                  if (connected)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: scheme.surface, width: 1.5),
                        ),
                        child: Icon(Icons.edit,
                            size: 11, color: scheme.onPrimary),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      connected
                          ? (session.username.isEmpty
                              ? 'Connected'
                              : session.username)
                          : 'This device',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                      connected
                          ? session.serverHost
                          : 'Not connected to a Vault server yet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!connected)
          FilledButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Connect to server'),
            onPressed: () => startConnectFlow(context, ref),
          )
        else
          OutlinedButton.icon(
            icon: const Icon(Icons.link_off),
            label: const Text('Disconnect this device'),
            onPressed: () => startDisconnectFlow(context, ref),
          ),
      ],
    );
  }
}

class _ServiceTile extends ConsumerWidget {
  const _ServiceTile({
    required this.service,
    required this.pinned,
    this.dockableIds,
  });

  final ServiceDefinition service;
  final bool pinned;

  /// Ids that count toward the dock cap (currently-dockable services).
  final Set<String>? dockableIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: AdaptiveIcon(service.icon),
      title: Text(service.label),
      onTap: () => _launch(context, service),
      trailing: IconButton(
        tooltip: pinned ? 'Unpin from dock' : 'Pin to dock',
        icon: Icon(
          pinned ? Icons.push_pin : Icons.push_pin_outlined,
          size: 20,
          color: pinned ? scheme.primary : scheme.onSurfaceVariant,
        ),
        onPressed: () async {
          VaultHaptics.selection();
          // The sidebar can hold any number of pins; only the mobile dock has
          // fixed slots.
          final capped = !FormFactor.isDesktopOf(context);
          final ok = await ref
              .read(pinnedServicesProvider.notifier)
              .toggle(service.id,
                  maxPins: capped ? kMaxDockPins : null,
                  countAmong: dockableIds);
          if (!ok && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Dock is full ($kMaxDockPins max) — unpin something first.'),
            ));
          }
        },
      ),
    );
  }

  /// Opens the service full-screen over the shell (dock and app bar hidden),
  /// with its own app bar carrying the service's actions and status widget.
  void _launch(BuildContext context, ServiceDefinition service) {
    // The root-navigator push escapes the shell's FormFactor scope, so carry
    // the current form factor along or desktop would get the mobile layout.
    final isDesktop = FormFactor.isDesktopOf(context);
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: Text(service.label),
          actions: [
            ActionBar(actions: service.actions),
            ?service.statusBar?.call(context),
            const SizedBox(width: 8),
          ],
        ),
        body: FormFactor(
            isDesktop: isDesktop, child: ServicePage(service: service)),
      ),
    ));
  }
}
