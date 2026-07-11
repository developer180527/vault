import 'capability.dart';

/// Where the capability manifest comes from. Two implementations:
/// [RemoteManifestSource] (the real home server, once it exists) and
/// [MockManifestSource] (a dev-only, editable manifest so the UI can be built
/// and demoed without a backend).
abstract interface class ManifestSource {
  Future<CapabilityManifest> fetch();
}

/// Talks to the home server. Unimplemented until the backend lands; calling it
/// throws, which drives the client into its fail-closed retry state rather
/// than silently granting anything.
class RemoteManifestSource implements ManifestSource {
  const RemoteManifestSource();

  @override
  Future<CapabilityManifest> fetch() async {
    throw UnimplementedError(
        'Remote manifest requires the Vault server (not built yet)');
  }
}

/// Editable in-memory manifest for development. The debug Settings panel
/// mutates it to simulate the server granting/revoking services and actions.
class MockManifestSource implements ManifestSource {
  MockManifestSource(this._current);

  CapabilityManifest _current;

  @override
  Future<CapabilityManifest> fetch() async => _current;

  void set(CapabilityManifest manifest) => _current = manifest;

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
