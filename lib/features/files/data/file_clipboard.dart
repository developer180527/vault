import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/file_node.dart';

/// A node that's been cut or copied, waiting to be pasted into a folder.
class ClipboardEntry {
  const ClipboardEntry({required this.node, required this.isCut});
  final FileNode node;

  /// Cut → the paste MOVES (and clears the clipboard); copy → the paste
  /// duplicates (and the clipboard stays, so you can paste again).
  final bool isCut;
}

/// The Files cut/copy clipboard — a single held node. Survives folder
/// navigation so you can cut here, browse into a target folder, and paste.
class FileClipboard extends Notifier<ClipboardEntry?> {
  @override
  ClipboardEntry? build() => null;

  void cut(FileNode node) => state = ClipboardEntry(node: node, isCut: true);
  void copy(FileNode node) => state = ClipboardEntry(node: node, isCut: false);
  void clear() => state = null;
}

final fileClipboardProvider =
    NotifierProvider<FileClipboard, ClipboardEntry?>(FileClipboard.new);
