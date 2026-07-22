import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/models/file_node.dart';
import 'package:vault/features/files/data/upload_queue.dart';

void main() {
  ProviderContainer make() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('start adds an uploading placeholder scoped to its parent', () {
    final c = make();
    final q = c.read(uploadQueueProvider.notifier);
    final id = q.start('folder-1', 'a.pdf', FileMediaKind.document, 100);

    final tasks = c.read(uploadQueueProvider);
    expect(tasks, hasLength(1));
    expect(tasks.single.tempId, id);
    expect(tasks.single.failed, isFalse);
    expect(tasks.single.toNode().syncStatus, SyncStatus.uploading);
    expect(q.forParent('folder-1'), hasLength(1));
    expect(q.forParent('other'), isEmpty);
  });

  test('fail flips the task to a failed node without dropping it', () {
    final c = make();
    final q = c.read(uploadQueueProvider.notifier);
    final id = q.start(null, 'b.jpg', FileMediaKind.image, 10);

    q.fail(id);
    final task = c.read(uploadQueueProvider).single;
    expect(task.failed, isTrue);
    expect(task.toNode().syncStatus, SyncStatus.failed);
  });

  test('remove drops the task (the success path)', () {
    final c = make();
    final q = c.read(uploadQueueProvider.notifier);
    final id = q.start(null, 'c.mp3', FileMediaKind.audio, 5);

    q.remove(id);
    expect(c.read(uploadQueueProvider), isEmpty);
  });

  test('tempIds are unique across same-named files', () {
    final c = make();
    final q = c.read(uploadQueueProvider.notifier);
    final a = q.start(null, 'dup.txt', FileMediaKind.document, 1);
    final b = q.start(null, 'dup.txt', FileMediaKind.document, 1);
    expect(a, isNot(b));
    expect(c.read(uploadQueueProvider), hasLength(2));
  });
}
