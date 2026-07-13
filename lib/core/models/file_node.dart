import 'package:flutter/foundation.dart';

/// Where a node's bytes are relative to this device. Orthogonal to
/// [ShareStatus] — this is about storage, not visibility.
enum SyncStatus {
  /// On the server, not downloaded here (files-on-demand default).
  remoteOnly,
  downloading,

  /// Cached/available locally and current.
  available,
  uploading,

  /// Created/added on this device, not yet uploaded.
  localOnly,
  failed,
}

/// Who can see a node. Orthogonal to [SyncStatus]. The v1 UI only *reads*
/// this; grant/revoke is a later feature.
enum ShareStatus { private, sharedByMe, sharedWithMe }

enum NodeKind { folder, file }

/// Coarse media classification, used to pick an icon and to decide whether
/// opening hands off to the media player.
enum FileMediaKind { none, image, video, audio, document }

/// A single item in the user's remote namespace, as mirrored locally. The UI
/// reads these from the local mirror; it never lists the server directly.
@immutable
class FileNode {
  const FileNode({
    required this.id,
    required this.parentId,
    required this.name,
    required this.kind,
    this.syncStatus = SyncStatus.remoteOnly,
    this.shareStatus = ShareStatus.private,
    this.pinned = false,
    this.mediaKind = FileMediaKind.none,
    this.size,
    this.modifiedAt,
    this.childCount,
    this.isConflicted = false,
  });

  final String id;

  /// Null for a place root.
  final String? parentId;
  final String name;
  final NodeKind kind;
  final SyncStatus syncStatus;
  final ShareStatus shareStatus;

  /// User asked to keep this available offline.
  final bool pinned;

  final FileMediaKind mediaKind;

  /// Bytes, for files.
  final int? size;
  final DateTime? modifiedAt;

  /// For folders, number of direct children (for the subtitle).
  final int? childCount;
  final bool isConflicted;

  bool get isFolder => kind == NodeKind.folder;
  bool get isMedia =>
      mediaKind == FileMediaKind.image ||
      mediaKind == FileMediaKind.video ||
      mediaKind == FileMediaKind.audio;

  FileNode copyWith({
    String? name,
    SyncStatus? syncStatus,
    ShareStatus? shareStatus,
    bool? pinned,
    DateTime? modifiedAt,
    int? childCount,
    bool? isConflicted,
  }) =>
      FileNode(
        id: id,
        parentId: parentId,
        name: name ?? this.name,
        kind: kind,
        syncStatus: syncStatus ?? this.syncStatus,
        shareStatus: shareStatus ?? this.shareStatus,
        pinned: pinned ?? this.pinned,
        mediaKind: mediaKind,
        size: size,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        childCount: childCount ?? this.childCount,
        isConflicted: isConflicted ?? this.isConflicted,
      );
}
