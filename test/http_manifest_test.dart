import 'package:flutter_test/flutter_test.dart';

import 'package:vault/core/capability/capability.dart';
import 'package:vault/core/client/http_vault_client.dart';

void main() {
  test('parses vaultd manifest JSON into CapabilityManifest', () {
    // Exactly what GET /v1/manifest returns (see vaultd handleManifest).
    final manifest = parseManifest({
      'device_id': 'dev-1',
      'profile_id': 'user-1',
      'username': 'venu',
      'capabilities': {
        'torrent': {
          'actions': ['read', 'write']
        },
        'media': {
          'actions': ['read', 'stream', 'bogus-future-action']
        },
      },
      'default_pinned': ['media', 'torrent'],
    });

    expect(manifest.deviceId, 'dev-1');
    expect(manifest.profileId, 'user-1');
    expect(manifest.defaultPinned, ['media', 'torrent']);
    expect(manifest.has('torrent'), isTrue);
    expect(manifest.can('torrent', CapabilityAction.write), isTrue);
    expect(manifest.can('torrent', CapabilityAction.delete), isFalse);
    expect(manifest.can('media', CapabilityAction.stream), isTrue);
    // Unknown action names from a newer server are ignored, not fatal.
    expect(manifest.capabilities['media']!.actions.length, 2);
    // Ungranted service: fail closed.
    expect(manifest.has('files'), isFalse);
  });

  test('empty/absent fields fail closed', () {
    final manifest = parseManifest({});
    expect(manifest.capabilities, isEmpty);
    expect(manifest.deviceId, '');
    expect(manifest.defaultPinned, isEmpty);
  });
}
