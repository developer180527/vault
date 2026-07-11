import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../capability/manifest_providers.dart';

/// Which services the user has pinned to the mobile bottom bar, persisted
/// per device. Defaults to the server's suggested order (`defaultPinned`) until
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
    return manifest?.defaultPinned ?? const [];
  }

  Future<void> _persist(List<String> ids) async {
    state = AsyncData(ids);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, ids);
  }

  Future<void> toggle(String serviceId) async {
    final current = state.asData?.value ?? const <String>[];
    final next = current.contains(serviceId)
        ? (List.of(current)..remove(serviceId))
        : (List.of(current)..add(serviceId));
    await _persist(next);
  }

  Future<void> setAll(List<String> ids) => _persist(ids);
}

final pinnedServicesProvider =
    AsyncNotifierProvider<PinnedServicesNotifier, List<String>>(
        PinnedServicesNotifier.new);
