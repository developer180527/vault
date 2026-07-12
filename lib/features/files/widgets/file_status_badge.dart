import 'package:flutter/material.dart';

import '../data/file_node.dart';

/// Compact trailing indicator that renders a node's *storage* state (and a
/// share marker when relevant) as small icons. Keeps the two axes visually
/// distinct: a share glyph, then the sync/availability glyph.
class FileStatusBadge extends StatelessWidget {
  const FileStatusBadge({super.key, required this.node});

  final FileNode node;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (node.shareStatus != ShareStatus.private) ...[
          Icon(
            node.shareStatus == ShareStatus.sharedByMe
                ? Icons.group_outlined
                : Icons.person_outline,
            size: 18,
            color: scheme.tertiary,
          ),
          const SizedBox(width: 8),
        ],
        _syncGlyph(scheme),
      ],
    );
  }

  Widget _syncGlyph(ColorScheme scheme) {
    if (node.isConflicted || node.syncStatus == SyncStatus.failed) {
      return Icon(Icons.error_outline, size: 18, color: scheme.error);
    }
    switch (node.syncStatus) {
      case SyncStatus.remoteOnly:
        return Icon(Icons.cloud_outlined, size: 18, color: scheme.outline);
      case SyncStatus.downloading:
      case SyncStatus.uploading:
        return SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: scheme.primary),
        );
      case SyncStatus.localOnly:
        return Icon(Icons.cloud_off_outlined,
            size: 18, color: scheme.outline);
      case SyncStatus.available:
        return node.pinned
            ? Icon(Icons.check_circle, size: 18, color: scheme.primary)
            : Icon(Icons.check_circle_outline,
                size: 18, color: scheme.outline);
      case SyncStatus.failed:
        return Icon(Icons.error_outline, size: 18, color: scheme.error);
    }
  }
}
