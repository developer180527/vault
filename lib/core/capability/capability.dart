import 'package:flutter/foundation.dart';

/// Actions a profile+device may be granted on a service. Presence of a
/// [Capability] at all means the service is *visible*; these gate operations
/// *within* it. The server is authoritative — the client only mirrors grants
/// to decide what to render and must never treat this as a security boundary
/// (the server re-checks every request).
///
/// Keep in lockstep with vaultd's KnownActions. `sync` gates the heavy
/// backup/sync engine, distinct from plain `write` — a view-only member may
/// browse without ever running sync.
enum CapabilityAction { read, write, delete, stream, share, sync, admin }

/// A single service grant for the current profile on the current device.
@immutable
class Capability {
  const Capability({
    required this.serviceId,
    this.actions = const {},
    this.config = const {},
  });

  final String serviceId;
  final Set<CapabilityAction> actions;

  /// Per-service server-supplied config (quotas, endpoints, flags).
  final Map<String, Object?> config;

  Capability copyWith({Set<CapabilityAction>? actions}) => Capability(
        serviceId: serviceId,
        actions: actions ?? this.actions,
        config: config,
      );
}

/// The full grant set for `(deviceId, profileId)`, fetched from the home
/// server after auth. Navigation and in-feature affordances derive entirely
/// from this — no entry means no tab, no route, no code path.
@immutable
class CapabilityManifest {
  const CapabilityManifest({
    required this.deviceId,
    required this.profileId,
    required this.capabilities,
    this.defaultPinned = const [],
  });

  final String deviceId;
  final String profileId;

  /// serviceId → capability.
  final Map<String, Capability> capabilities;

  /// Server-suggested default order for the mobile pinned bar.
  final List<String> defaultPinned;

  bool has(String serviceId) => capabilities.containsKey(serviceId);

  bool can(String serviceId, CapabilityAction action) =>
      capabilities[serviceId]?.actions.contains(action) ?? false;

  /// The fail-closed value: nothing is granted.
  static const empty = CapabilityManifest(
    deviceId: '',
    profileId: '',
    capabilities: {},
  );

  CapabilityManifest withCapabilities(Map<String, Capability> next) =>
      CapabilityManifest(
        deviceId: deviceId,
        profileId: profileId,
        capabilities: next,
        defaultPinned: defaultPinned,
      );
}
