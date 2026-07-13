import 'package:flutter/material.dart';

import '../../../core/models/file_node.dart';
import 'file_status_badge.dart';

/// One row in the file list, used on both form factors. Shows a kind icon, the
/// name, a subtitle (child count for folders, size + modified for files), and
/// the storage/share status badge.
class FileRow extends StatelessWidget {
  const FileRow({super.key, required this.node, required this.onTap});

  final FileNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(_icon(), color: node.isFolder ? scheme.primary : null),
      title: Text(node.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(_subtitle()),
      trailing: FileStatusBadge(node: node),
      onTap: onTap,
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

  String _subtitle() {
    if (node.isFolder) {
      final n = node.childCount ?? 0;
      return '$n item${n == 1 ? '' : 's'}';
    }
    final parts = <String>[if (node.size != null) _formatSize(node.size!)];
    if (node.modifiedAt != null) parts.add(_formatDate(node.modifiedAt!));
    return parts.join(' · ');
  }

  static String _formatSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var i = 0;
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    final str = size >= 100 || i == 0
        ? size.toStringAsFixed(0)
        : size.toStringAsFixed(1);
    return '$str ${units[i]}';
  }

  static String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
