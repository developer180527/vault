import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vault/features/files/data/file_browser_controller.dart';
import 'package:vault/core/models/file_node.dart';

void main() {
  test('createFolder adds an optimistic localOnly node', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final repo = container.read(fileRepositoryProvider);

    final before = await repo.children(null);
    await repo.createFolder(null, 'New Stuff');
    final after = await repo.children(null);

    expect(after.length, before.length + 1);
    final created = after.firstWhere((n) => n.name == 'New Stuff');
    expect(created.isFolder, isTrue);
    expect(created.syncStatus, SyncStatus.localOnly);
  });

  test('uploadFile streams bytes and lands an available node', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final repo = container.read(fileRepositoryProvider);

    final bytes = Stream<List<int>>.fromIterable([
      [1, 2, 3],
      [4, 5, 6],
    ]);
    final id = await repo.uploadFile(null, 'clip.mp4', bytes, 6,
        mediaKind: FileMediaKind.video);
    final node = await repo.node(id);
    expect(node!.syncStatus, SyncStatus.available);
    expect(node.mediaKind, FileMediaKind.video);
    expect(node.size, 6);
  });

  test('pin flips a remote-only file to available + pinned', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final repo = container.read(fileRepositoryProvider);

    await repo.setPinned('backup.zip', true); // was remoteOnly
    final node = await repo.node('backup.zip');
    expect(node!.pinned, isTrue);
    expect(node.syncStatus, SyncStatus.available);
  });

  test('trash removes the node and decrements its parent count', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final repo = container.read(fileRepositoryProvider);

    final docsBefore = (await repo.node('documents'))!.childCount;
    await repo.trash('resume.pdf'); // child of documents
    expect(await repo.node('resume.pdf'), isNull);
    expect((await repo.node('documents'))!.childCount, docsBefore! - 1);
  });
}
