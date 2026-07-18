import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../capability/manifest_providers.dart';
import '../services/service_registry.dart';

/// Hard cap on dock pins — the dock row is static (no scrolling), so this is
/// what fits comfortably beside the fixed You slot on a phone. Everything else
/// is one tap away on the You page.
const kMaxDockPins = 4;

/// Which services the user has pinned to the mobile dock, persisted per
/// device. Defaults to the server's suggested order (`defaultPinned`) until
/// the user customizes it. The shell intersects this with currently-permitted
/// services, so a revoked pin simply drops off.
class PinnedServicesNotifier extends AsyncNotifier<List<String>> {
  static const _key = 'pinned_services_v1';

  @override
  Future<List<String>> build() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_key);
    if (stored != null) return stored;
    final manifest = ref.watch(manifestProvider).asData?.value;
    final defaults = List<String>.of(manifest?.defaultPinned ?? const []);
    // Always-available LOCAL content services (e.g. Media, which browses the
    // device's own photos) belong on the dock even when the server grants
    // nothing — otherwise a no-grant member has an empty bottom nav. Lead with
    // them; 'user' is the detached You slot and 'settings' lives behind its
    // gear, so neither is a dock pin.
    for (final s in ref.watch(serviceRegistryProvider)) {
      if (s.alwaysAvailable &&
          s.id != 'user' &&
          s.id != 'settings' &&
          !defaults.contains(s.id)) {
        defaults.insert(0, s.id);
      }
    }
    return defaults;
  }

  Future<void> _persist(List<String> ids) async {
    state = AsyncData(ids);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, ids);
  }

  /// Pin/unpin a service. [maxPins] caps how many can be pinned (pass
  /// [kMaxDockPins] from the mobile dock; null for the desktop sidebar, which
  /// can hold any number). Returns false when pinning would exceed the cap
  /// (the caller tells the user to unpin something first).
  Future<bool> toggle(String serviceId, {int? maxPins}) async {
    final current = state.asData?.value ?? const <String>[];
    if (current.contains(serviceId)) {
      await _persist(List.of(current)..remove(serviceId));
    } else {
      if (maxPins != null && current.length >= maxPins) return false;
      await _persist([...current, serviceId]);
    }
    return true;
  }
}

final pinnedServicesProvider =
    AsyncNotifierProvider<PinnedServicesNotifier, List<String>>(
        PinnedServicesNotifier.new);
