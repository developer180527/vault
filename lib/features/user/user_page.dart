import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions/vault_action.dart';
import '../../core/capability/manifest_providers.dart';
import '../../core/platform/design/adaptive_icons.dart';
import '../../core/platform/haptics.dart';
import '../../core/prefs/pinned_services.dart';
import '../../core/services/service_registry.dart';
import '../../shell/adaptive_shell.dart';
import '../../shell/service_page.dart';
import '../../shell/widgets/action_bar.dart';
import '../settings/settings_page.dart';

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

/// The You page: who's signed in (a local placeholder until vaultd auth
/// exists) and the full services shelf. Every permitted service is listed;
/// tapping launches it full-screen (the dock hides), the pin toggles whether
/// it lives on the dock.
class UserPage extends ConsumerWidget {
  const UserPage({super.key});

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
      // Inset for the shell's translucent toolbar and floating dock, so the
      // page scrolls beneath both.
      padding: EdgeInsets.fromLTRB(
          16,
          16 + MediaQuery.paddingOf(context).top,
          16,
          16 + MediaQuery.paddingOf(context).bottom),
      children: [
        const _ProfileHeader(),
        const SizedBox(height: 24),
        Text('Services',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        for (final s in shelf)
          _ServiceTile(service: s, pinned: pinnedIds.contains(s.id)),
      ],
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        CircleAvatar(
          radius: 32,
          backgroundColor: scheme.secondaryContainer,
          child: Icon(Icons.person_outline,
              size: 36, color: scheme.onSecondaryContainer),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This device',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              // TODO(backend): show the signed-in identity, device name, and
              // grants once vaultd auth exists.
              Text('Not connected to a Vault server yet',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

class _ServiceTile extends ConsumerWidget {
  const _ServiceTile({required this.service, required this.pinned});

  final ServiceDefinition service;
  final bool pinned;

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
              .toggle(service.id, maxPins: capped ? kMaxDockPins : null);
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
