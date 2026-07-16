import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import '../client/vault_client.dart';
import '../logging/vault_log.dart';
import '../services/service_registry.dart';
import 'capability.dart';
import 'manifest_source.dart';

final _log = VaultLog.tag('capability');

/// The editable dev manifest (debug only). The Settings dev panel mutates this
/// to simulate the server changing grants; [manifestProvider] mirrors it.
class MockManifestNotifier extends Notifier<CapabilityManifest> {
  @override
  CapabilityManifest build() {
    final services = ref.watch(serviceRegistryProvider);
    return MockManifestSource.fullGrant(services.map((s) => s.id));
  }

  void setServiceGranted(String serviceId, bool granted) {
    final next = Map.of(state.capabilities);
    if (granted) {
      next[serviceId] = Capability(
        serviceId: serviceId,
        actions: CapabilityAction.values.toSet(),
      );
    } else {
      next.remove(serviceId);
    }
    state = state.withCapabilities(next);
  }

  void setAction(String serviceId, CapabilityAction action, bool on) {
    final cap = state.capabilities[serviceId];
    if (cap == null) return;
    final actions = Set.of(cap.actions);
    on ? actions.add(action) : actions.remove(action);
    state = state.withCapabilities({
      ...state.capabilities,
      serviceId: cap.copyWith(actions: actions),
    });
  }
}

final mockManifestProvider =
    NotifierProvider<MockManifestNotifier, CapabilityManifest>(
        MockManifestNotifier.new);

/// The authoritative manifest for the session. Loading → splash; error →
/// fail-closed retry (never "assume allowed"); data → drives all navigation.
class ManifestController extends AsyncNotifier<CapabilityManifest> {
  @override
  Future<CapabilityManifest> build() async {
    // Connected to a real server → its manifest is the only authority.
    // Not connected → the editable mock keeps the app usable standalone
    // (and drives all tests). Watching the session makes login/logout flip
    // the whole app's navigation automatically.
    final session = ref.watch(sessionProvider).asData?.value;
    if (session == null) {
      final manifest = ref.watch(mockManifestProvider);
      _log.debug('Using mock manifest (no server session)', fields: {
        'services': manifest.capabilities.length,
      });
      return manifest;
    }
    try {
      final manifest = await ref.watch(vaultClientProvider).fetchManifest();
      _log.info('Capability manifest loaded', fields: {
        'profile': manifest.profileId,
        'services': manifest.capabilities.length,
      });
      return manifest;
    } catch (e, s) {
      // Fail-closed: log why, the UI shows the retry screen.
      _log.error('Manifest fetch failed — failing closed',
          error: e, stackTrace: s);
      rethrow;
    }
  }

  /// Re-fetch after a failure (the retry button) or when the server signals a
  /// grant change.
  Future<void> reload() async {
    state = const AsyncLoading();
    ref.invalidateSelf();
    await future;
  }
}

final manifestProvider =
    AsyncNotifierProvider<ManifestController, CapabilityManifest>(
        ManifestController.new);

/// Services the current profile+device may see, in registry order. Empty until
/// the manifest resolves. `alwaysAvailable` services (account/settings) survive
/// even a sparse manifest so the user is never locked out of their own device.
final permittedServicesProvider = Provider<List<ServiceDefinition>>((ref) {
  final manifest = ref.watch(manifestProvider).asData?.value;
  final all = ref.watch(serviceRegistryProvider);
  if (manifest == null) return const [];
  return [
    for (final s in all)
      if (s.alwaysAvailable || manifest.has(s.id)) s,
  ];
});

/// Whether a specific action is granted on a service — for gating in-feature
/// controls (hide "New Folder" without `write`, etc.). Fail-closed.
final canProvider =
    Provider.family<bool, ({String serviceId, CapabilityAction action})>(
        (ref, key) {
  final manifest = ref.watch(manifestProvider).asData?.value;
  return manifest?.can(key.serviceId, key.action) ?? false;
});
