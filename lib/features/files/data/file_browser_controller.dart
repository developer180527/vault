import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_node.dart';
import 'file_repository.dart';

final fileRepositoryProvider =
    Provider<FileRepository>((ref) => MockFileRepository());

/// Browse location plus Finder-style back/forward history. `currentId` is null
/// at the My Files root.
@immutable
class BrowseState {
  const BrowseState({
    this.currentId,
    this.back = const [],
    this.forward = const [],
  });

  final String? currentId;
  final List<String?> back;
  final List<String?> forward;

  bool get canBack => back.isNotEmpty;
  bool get canForward => forward.isNotEmpty;
}

/// Navigation for the file browser, shared by desktop and mobile. Holds the
/// visited-folder history so the toolbar's back/forward arrows work like a
/// browser/Finder.
class FileBrowserController extends Notifier<BrowseState> {
  @override
  BrowseState build() => const BrowseState();

  /// Navigate to [id] (a folder, or null for root), recording history.
  void navigateTo(String? id) {
    if (id == state.currentId) return;
    state = BrowseState(
      currentId: id,
      back: [...state.back, state.currentId],
      forward: const [],
    );
  }

  void openFolder(String id) => navigateTo(id);
  void goTo(String? id) => navigateTo(id);

  void goBack() {
    if (!state.canBack) return;
    final prev = state.back.last;
    state = BrowseState(
      currentId: prev,
      back: state.back.sublist(0, state.back.length - 1),
      forward: [state.currentId, ...state.forward],
    );
  }

  void goForward() {
    if (!state.canForward) return;
    final next = state.forward.first;
    state = BrowseState(
      currentId: next,
      back: [...state.back, state.currentId],
      forward: state.forward.sublist(1),
    );
  }
}

final fileBrowserControllerProvider =
    NotifierProvider<FileBrowserController, BrowseState>(
        FileBrowserController.new);

/// Children of the current folder, from the local mirror.
final currentChildrenProvider = FutureProvider<List<FileNode>>((ref) {
  final parentId = ref.watch(fileBrowserControllerProvider).currentId;
  return ref.watch(fileRepositoryProvider).children(parentId);
});

/// Breadcrumb chain from root to the current folder.
final breadcrumbProvider = FutureProvider<List<FileNode>>((ref) async {
  final id = ref.watch(fileBrowserControllerProvider).currentId;
  if (id == null) return const [];
  return ref.watch(fileRepositoryProvider).pathTo(id);
});

/// Name of the current folder for the toolbar (Finder shows this by the arrows).
final currentDirectoryNameProvider = FutureProvider<String>((ref) async {
  final id = ref.watch(fileBrowserControllerProvider).currentId;
  if (id == null) return 'My Files';
  final node = await ref.watch(fileRepositoryProvider).node(id);
  return node?.name ?? 'My Files';
});
