import 'capability.dart';

/// Dev-only manifest helpers. Fetching the *real* manifest goes through the
/// VaultClient seam (`VaultClient.fetchManifest`), not through this file; the
/// debug Settings panel uses [MockManifestSource.fullGrant] to seed the
/// editable manifest it mutates to simulate grant changes.
class MockManifestSource {
  /// A generous default so every service shows while developing.
  static CapabilityManifest fullGrant(Iterable<String> serviceIds) =>
      CapabilityManifest(
        deviceId: 'dev-device',
        profileId: 'dev-profile',
        capabilities: {
          for (final id in serviceIds)
            id: Capability(
              serviceId: id,
              actions: CapabilityAction.values.toSet(),
            ),
        },
        defaultPinned: serviceIds.take(4).toList(),
      );
}
