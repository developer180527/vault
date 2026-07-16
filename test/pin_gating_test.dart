import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vault/app.dart';
import 'package:vault/core/capability/manifest_providers.dart';
import 'package:vault/core/client/vault_client.dart';
import 'package:vault/core/models/file_node.dart';
import 'package:vault/core/services/service_registry.dart';
import 'package:vault/features/files/data/file_browser_controller.dart';
import 'package:vault/features/files/file_actions.dart';

/// Repository stub whose only interesting property is [supportsPinning].
class _NoPinRepo implements FileRepository {
  const _NoPinRepo();

  @override
  bool get supportsPinning => false;

  @override
  Future<List<FileNode>> children(String? parentId) async => const [];
  @override
  Future<FileNode?> node(String id) async => null;
  @override
  Future<List<FileNode>> pathTo(String id) async => const [];
  @override
  Future<String> createFolder(String? parentId, String name) async => '';
  @override
  Future<String> addLocalFile(String? parentId, String name,
          {int? size, FileMediaKind mediaKind = FileMediaKind.none}) async =>
      '';
  @override
  Future<void> rename(String id, String newName) async {}
  @override
  Future<void> setPinned(String id, bool pinned) async =>
      throw UnsupportedError('pinning not supported');
  @override
  Future<void> trash(String id) async {}
}

void main() {
  const file = FileNode(
    id: 'f1',
    parentId: null,
    name: 'doc.pdf',
    kind: NodeKind.file,
  );

  /// Evaluates the pin action's enablement using a real WidgetRef (the gate
  /// reads providers), optionally overriding the repository. Samples only
  /// after the (async) manifest resolves — before that everything fails
  /// closed by design, which isn't what these tests measure.
  Future<bool> pinEnabled(WidgetTester tester, {FileRepository? repo}) async {
    bool? enabled;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        serviceRegistryProvider.overrideWithValue(vaultServices),
        if (repo != null) fileRepositoryProvider.overrideWithValue(repo),
      ],
      child: Consumer(builder: (context, ref, _) {
        final manifestReady = ref.watch(manifestProvider).hasValue;
        if (manifestReady) {
          final pin =
              fileItemActions(file).where((a) => a.id == 'file.pin').single;
          enabled = pin.enabled(ref);
        }
        return const SizedBox.shrink();
      }),
    ));
    for (var i = 0; i < 50 && enabled == null; i++) {
      await tester.pump();
    }
    expect(enabled, isNotNull, reason: 'manifest never resolved');
    return enabled!;
  }

  testWidgets(
      'pin action is HIDDEN when the backend cannot honor pinning (HTTP mode)',
      (tester) async {
    final enabled = await pinEnabled(tester, repo: const _NoPinRepo());
    expect(enabled, isFalse);
  });

  testWidgets('pin action shows on the mock backend (standalone mode)',
      (tester) async {
    // Default container → no session → MockVaultClient, which supports pinning.
    final enabled = await pinEnabled(tester);
    expect(enabled, isTrue);
  });
}
