import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/file_node.dart';

/// One in-flight (or just-failed) upload, shown as a placeholder row in the
/// folder it's going into until it completes. Identified by [tempId] — a
/// synthetic node id that never collides with a server id.
class UploadTask {
  const UploadTask({
    required this.tempId,
    required this.parentId,
    required this.name,
    required this.mediaKind,
    required this.size,
    this.failed = false,
  });

  final String tempId;
  final String? parentId;
  final String name;
  final FileMediaKind mediaKind;
  final int size;
  final bool failed;

  UploadTask asFailed() => UploadTask(
        tempId: tempId,
        parentId: parentId,
        name: name,
        mediaKind: mediaKind,
        size: size,
        failed: true,
      );

  /// Rendered in the browser as a placeholder node: a spinner while uploading,
  /// an error glyph once failed (both via [FileStatusBadge]).
  FileNode toNode() => FileNode(
        id: tempId,
        parentId: parentId,
        name: name,
        kind: NodeKind.file,
        mediaKind: mediaKind,
        size: size,
        syncStatus: failed ? SyncStatus.failed : SyncStatus.uploading,
      );
}

/// Tracks manual uploads so the browser can show their progress/failure. A
/// successful upload is *removed* (the real server node replaces it on the next
/// listing refresh) — so a settled, successfully-uploaded file carries no
/// placeholder and no lingering badge.
class UploadQueue extends Notifier<List<UploadTask>> {
  var _seq = 0;

  @override
  List<UploadTask> build() => const [];

  /// Register a starting upload; returns its [tempId].
  String start(String? parentId, String name, FileMediaKind mediaKind, int size) {
    final tempId = 'upload:${_seq++}:$name';
    state = [
      ...state,
      UploadTask(
          tempId: tempId,
          parentId: parentId,
          name: name,
          mediaKind: mediaKind,
          size: size),
    ];
    return tempId;
  }

  /// Mark an upload failed (keeps the row, now with an error badge).
  void fail(String tempId) {
    state = [
      for (final t in state) t.tempId == tempId ? t.asFailed() : t,
    ];
  }

  /// Drop a task (on success, or when the user dismisses a failed one).
  void remove(String tempId) {
    state = [for (final t in state) if (t.tempId != tempId) t];
  }

  /// The tasks going into [parentId], for merging into that folder's listing.
  List<UploadTask> forParent(String? parentId) =>
      [for (final t in state) if (t.parentId == parentId) t];
}

final uploadQueueProvider =
    NotifierProvider<UploadQueue, List<UploadTask>>(UploadQueue.new);
