import 'package:flutter/material.dart';

import '../data/file_node.dart';
import 'file_status_badge.dart';

/// Grid-view tile for a file/folder (the "grid" View mode). A large kind icon,
/// the name, and the status badge in the corner.
class FileTile extends StatelessWidget {
  const FileTile({super.key, required this.node, required this.onTap});

  final FileNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: FileStatusBadge(node: node),
              ),
              Expanded(
                child: Icon(
                  _icon(),
                  size: 44,
                  color: node.isFolder ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              Text(
                node.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _icon() {
    if (node.isFolder) return Icons.folder;
    return switch (node.mediaKind) {
      FileMediaKind.image => Icons.image_outlined,
      FileMediaKind.video => Icons.movie_outlined,
      FileMediaKind.audio => Icons.music_note_outlined,
      FileMediaKind.document => Icons.description_outlined,
      FileMediaKind.none => Icons.insert_drive_file_outlined,
    };
  }
}
