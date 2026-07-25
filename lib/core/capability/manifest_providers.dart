import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/session.dart';
import '../cache/content_cache.dart';
import '../client/http_vault_client.dart';
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

/// Whether the home server is currently reachable. False when the last
/// manifest fetch failed (we're running on a cached/local manifest). Drives
/// the offline banner and per-page "can't connect" states — NOT security,
/// which the server always re-checks.
class ServerReachable extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool v) {
    if (state != v) state = v;
  }
}

final serverReachableProvider =
    NotifierProvider<ServerReachable, bool>(ServerReachable.new);

/// The authoritative manifest for the session. Connected + reachable → the
/// server's manifest. Connected + UNREACHABLE → the last-cached manifest, or
/// a local-only one, so the app is never blocked by a full-screen error: the
/// always-available tabs (Media, Settings, You) work, and server-backed pages
/// show their own "can't connect" state. Not connected → the editable mock.
class ManifestController extends AsyncNotifier<CapabilityManifest> {
  @override
  Future<CapabilityManifest> build() async {
    // select on server+device IDENTITY: login/logout and server switches
    // refetch, but session MUTATIONS (token refresh, noteUsername — which
    // fetchManifest itself triggers) must not cancel the in-flight fetch.
    final scope = ref.watch(sessionProvider.select((s) {
      final v = s.asData?.value;
      return v == null ? null : '${v.serverHost}/${v.deviceId}';
    }));
    if (scope == null) {
      final manifest = ref.watch(mockManifestProvider);
      _log.debug('Using mock manifest (no server session)', fields: {
        'services': manifest.capabilities.length,
      });
      return manifest;
    }

    final cache = ref.watch(contentCacheProvider);
    final cacheKey = '$scope/manifest';
    try {
      final manifest = await ref.watch(vaultClientProvider).fetchManifest();
      // Persist for offline starts; mark the server reachable.
      unawaited(cache.writeSnapshot(cacheKey,
          jsonEncode(manifestToJson(manifest))));
      _reach(true);
      _log.info('Capability manifest loaded', fields: {
        'profile': manifest.profileId,
        'services': manifest.capabilities.length,
      });
      return manifest;
    } catch (e) {
      // A stale build (this ref was rebuilt/disposed mid-fetch) is not a
      // failure — a newer fetch owns the state.
      if (!ref.mounted) rethrow;
      _reach(false);
      // Degrade gracefully instead of failing closed to a blocking screen.
      final cached = await cache.readSnapshot(cacheKey);
      if (cached != null) {
        try {
          final manifest =
              parseManifest(jsonDecode(cached) as Map<String, Object?>);
          _log.warn('manifest fetch failed — serving cached manifest '
              '(offline)', fields: {'services': manifest.capabilities.length});
          return manifest;
        } catch (_) {/* corrupt cache → fall through to local-only */}
      }
      // Never connected on this device (no cache): local-only. The empty
      // manifest still yields the always-available tabs via
      // permittedServicesProvider, so the user is never stranded.
      _log.warn('manifest fetch failed, no cache — local-only mode',
          fields: {'err': '$e'});
      final sess = ref.read(sessionProvider).asData?.value;
      return CapabilityManifest(
        deviceId: sess?.deviceId ?? '',
        profileId: '',
        capabilities: const {},
      );
    }
  }

  /// Update reachability off the build stack (mutating another provider during
  /// build is disallowed).
  void _reach(bool up) =>
      Future.microtask(() => ref.read(serverReachableProvider.notifier).set(up));

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
