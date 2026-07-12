import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vault/features/files/data/file_browser_controller.dart';
import 'package:vault/features/files/data/file_node.dart';

void main() {
  test('root lists folders first, then files, alphabetically', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final nodes = await container.read(currentChildrenProvider.future);
    final folders = nodes.where((n) => n.isFolder).toList();
    final files = nodes.where((n) => !n.isFolder).toList();

    // All folders precede all files.
    expect(nodes.indexOf(folders.last), lessThan(nodes.indexOf(files.first)));
    // Folders sorted by name.
    expect(folders.map((f) => f.name),
        containsAllInOrder(['Documents', 'Movies', 'Photos']));
  });

  test('opening a folder updates children and breadcrumb', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(currentChildrenProvider.future);

    container.read(fileBrowserControllerProvider.notifier).openFolder('photos');

    final children = await container.read(currentChildrenProvider.future);
    expect(children.map((n) => n.name), contains('family.jpg'));

    final crumbs = await container.read(breadcrumbProvider.future);
    expect(crumbs.map((c) => c.name), ['Photos']);
  });

  test('back/forward history navigates like a browser', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final nav = container.read(fileBrowserControllerProvider.notifier);

    expect(container.read(fileBrowserControllerProvider).canBack, isFalse);

    nav.openFolder('documents');
    nav.openFolder('photos');
    var state = container.read(fileBrowserControllerProvider);
    expect(state.currentId, 'photos');
    expect(state.canBack, isTrue);
    expect(state.canForward, isFalse);

    nav.goBack();
    state = container.read(fileBrowserControllerProvider);
    expect(state.currentId, 'documents');
    expect(state.canForward, isTrue);

    nav.goForward();
    expect(container.read(fileBrowserControllerProvider).currentId, 'photos');

    // Navigating somewhere new clears the forward stack.
    nav.goBack();
    nav.openFolder('movies');
    expect(container.read(fileBrowserControllerProvider).canForward, isFalse);
  });

  test('mock exercises every sync status for badge coverage', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final repo = container.read(fileRepositoryProvider);

    final all = <FileNode>[];
    Future<void> collect(String? parent) async {
      for (final n in await repo.children(parent)) {
        all.add(n);
        if (n.isFolder) await collect(n.id);
      }
    }

    await collect(null);
    final statuses = all.map((n) => n.syncStatus).toSet();
    expect(statuses, containsAll(SyncStatus.values));
    expect(all.any((n) => n.pinned), isTrue);
    expect(all.any((n) => n.shareStatus != ShareStatus.private), isTrue);
    expect(all.any((n) => n.isConflicted), isTrue);
  });
}
