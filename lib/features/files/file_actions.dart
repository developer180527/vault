import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/actions/vault_action.dart';
import '../../core/auth/session.dart';
import '../../core/capability/capability.dart';
import '../../core/capability/manifest_providers.dart';
import '../../core/logging/vault_log.dart';
import '../../core/platform/design/adaptive_icons.dart';
import '../../core/platform/platform_services.dart';
import 'data/file_browser_controller.dart';
import 'data/file_clipboard.dart';
import 'data/file_download.dart';
import 'data/upload_queue.dart';
import 'server_file_preview.dart';
import '../../core/models/file_node.dart';
import 'data/files_view.dart';
import 'synced_folders_page.dart';

final _log = VaultLog.tag('files');

/// Capability gates for the Files service.
bool _canWrite(WidgetRef ref) =>
    ref.read(canProvider((serviceId: 'files', action: CapabilityAction.write)));
bool _canDelete(WidgetRef ref) => ref
    .read(canProvider((serviceId: 'files', action: CapabilityAction.delete)));

/// Re-reads the current folder after a mutation (optimistic: the mock already
/// changed; this refreshes the view).
void _refresh(WidgetRef ref) {
  ref.invalidate(currentChildrenProvider);
  ref.invalidate(breadcrumbProvider);
}

/// Service-level actions for the Files toolbar + palette.
final filesServiceActions = <VaultAction>[
  VaultAction(
    id: 'files.sync-folder',
    label: 'Synced folders',
    icon: VaultIcons.sync,
    isEnabled: _canWrite,
    onInvoke: (context, ref) async => openSyncedFolders(context),
  ),
  VaultAction(
    id: 'files.new-folder',
    label: 'New Folder',
    icon: VaultIcons.newFolder,
    isEnabled: _canWrite,
    onInvoke: (context, ref) async {
      final name = await _promptName(context, title: 'New folder');
      if (name == null) return;
      final parent = ref.read(fileBrowserControllerProvider).currentId;
      await ref.read(fileRepositoryProvider).createFolder(parent, name);
      _log.info('Created folder', fields: {'parent': parent, 'name': name});
      _refresh(ref);
    },
  ),
  VaultAction(
    id: 'files.upload',
    label: 'Upload',
    icon: VaultIcons.upload,
    isEnabled: _canWrite,
    onInvoke: (context, ref) async {
      final picked = await ref
          .read(fileSystemAccessProvider)
          .pickFiles(allowMultiple: true);
      if (picked.isEmpty) return;
      final parent = ref.read(fileBrowserControllerProvider).currentId;
      final repo = ref.read(fileRepositoryProvider);
      final queue = ref.read(uploadQueueProvider.notifier);
      // Upload sequentially; each file shows a placeholder row (spinner →
      // gone on success, error badge on failure) in the target folder.
      for (final f in picked) {
        final kind = _mediaKindFor(f.mimeType, f.name);
        final tempId = queue.start(parent, f.name, kind, f.size);
        try {
          await repo.uploadFile(parent, f.name, f.openRead(), f.size,
              mediaKind: kind);
          queue.remove(tempId);
          _refresh(ref); // the real server node replaces the placeholder
        } catch (e) {
          _log.warn('upload failed',
              fields: {'name': f.name, 'err': '$e'});
          queue.fail(tempId); // row stays with an error badge
        }
      }
      _log.info('Uploads finished',
          fields: {'parent': parent, 'count': picked.length});
    },
  ),
  VaultAction(
    id: 'files.paste',
    label: 'Paste',
    icon: VaultIcons.paste,
    // Reactive: watch so the toolbar/menu shows Paste the moment something is
    // cut or copied. Needs write to land the node in this folder.
    isEnabled: (ref) =>
        ref.watch(fileClipboardProvider) != null && _canWrite(ref),
    onInvoke: (context, ref) async {
      final clip = ref.read(fileClipboardProvider);
      if (clip == null) return;
      final parent = ref.read(fileBrowserControllerProvider).currentId;
      final repo = ref.read(fileRepositoryProvider);
      final messenger = ScaffoldMessenger.of(context);
      try {
        if (clip.isCut) {
          await repo.move(clip.node.id, parent);
          ref.read(fileClipboardProvider.notifier).clear();
        } else {
          await repo.copy(clip.node.id, parent);
        }
        _log.info('pasted', fields: {
          'name': clip.node.name,
          'move': clip.isCut,
          'into': parent ?? 'root',
        });
        _refresh(ref);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Paste failed: $e')));
      }
    },
  ),
  VaultAction(
    id: 'files.toggle-view',
    label: 'Toggle List / Grid',
    icon: VaultIcons.toggleView,
    onInvoke: (context, ref) =>
        ref.read(filesViewModeProvider.notifier).toggle(),
  ),
];

/// Item-level actions for a file/folder row's context menu, composed from two
/// sections so the menu scales per file kind:
///
///   [kind-specific actions] + [actions common to every node]
///
/// Supporting a new file type (or giving one extra tools — "Set as wallpaper",
/// "Extract archive"…) means extending [_kindActions] only; the common tail
/// (offline, rename, trash) stays uniform everywhere.
List<VaultAction> fileItemActions(FileNode node) => [
      ..._kindActions(node),
      ..._commonActions(node),
    ];

/// The kind-specific section: what "opening" means for this node, plus any
/// per-kind extras.
List<VaultAction> _kindActions(FileNode node) {
  if (node.isFolder) {
    return [
      VaultAction(
        id: 'file.open',
        label: 'Open',
        icon: VaultIcons.folderOpen,
        onInvoke: (context, ref) =>
            ref.read(fileBrowserControllerProvider.notifier).openFolder(node.id),
      ),
    ];
  }

  final (label, icon) = switch (node.mediaKind) {
    FileMediaKind.image => ('View Photo', VaultIcons.photo),
    FileMediaKind.video => ('Play Video', VaultIcons.playVideo),
    FileMediaKind.audio => ('Play Audio', VaultIcons.music),
    FileMediaKind.document => ('Open Document', VaultIcons.document),
    FileMediaKind.none => ('Open / Preview', VaultIcons.openPreview),
  };
  return [
    VaultAction(
      id: 'file.open',
      label: label,
      icon: icon,
      // In-app preview routed by kind: image viewer, video/audio player, or
      // the document viewer (PDF/markdown/code/text). Unpreviewable types fall
      // back to a "use Download" hint.
      onInvoke: (context, ref) => openServerFileNode(context, ref, node),
    ),
  ];
}

/// Actions every node gets, regardless of kind.
List<VaultAction> _commonActions(FileNode node) => [
      // Cut / Copy → the clipboard; Paste (folder toolbar) lands it here. Both
      // files and folders can be moved/copied. Needs write.
      VaultAction(
        id: 'file.cut',
        label: 'Cut',
        icon: VaultIcons.cut,
        isEnabled: _canWrite,
        onInvoke: (context, ref) {
          ref.read(fileClipboardProvider.notifier).cut(node);
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Cut “${node.name}” — Paste into a folder')));
        },
      ),
      VaultAction(
        id: 'file.copy',
        label: 'Copy',
        icon: VaultIcons.copy,
        isEnabled: _canWrite,
        onInvoke: (context, ref) {
          ref.read(fileClipboardProvider.notifier).copy(node);
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Copied “${node.name}” — Paste into a folder')));
        },
      ),
      if (!node.isFolder)
        VaultAction(
          id: 'file.download',
          label: 'Download',
          icon: VaultIcons.downloads,
          // Server files only: needs a connected session to fetch the bytes.
          isEnabled: (ref) =>
              ref.read(sessionProvider).asData?.value != null,
          onInvoke: (context, ref) =>
              downloadFileToLocal(context, ref, node),
        ),
      if (!node.isFolder)
        VaultAction(
          id: 'file.pin',
          label: node.pinned ? 'Remove from Offline' : 'Make Available Offline',
          icon: node.pinned
              ? VaultIcons.offlineRemove
              : VaultIcons.offlineAdd,
          // Hidden entirely when the backend can't honor pinning (the HTTP
          // client until sync lands) — never show a control that no-ops.
          isEnabled: (ref) =>
              ref.read(fileRepositoryProvider).supportsPinning &&
              _canWrite(ref),
          onInvoke: (context, ref) async {
            await ref
                .read(fileRepositoryProvider)
                .setPinned(node.id, !node.pinned);
            _refresh(ref);
          },
        ),
      VaultAction(
        id: 'file.rename',
        label: 'Rename',
        icon: VaultIcons.rename,
        isEnabled: _canWrite,
        onInvoke: (context, ref) async {
          final name =
              await _promptName(context, title: 'Rename', initial: node.name);
          if (name == null) return;
          await ref.read(fileRepositoryProvider).rename(node.id, name);
          _refresh(ref);
        },
      ),
      VaultAction(
        id: 'file.delete',
        label: 'Move to Trash',
        icon: VaultIcons.trash,
        isDestructive: true,
        isEnabled: _canDelete,
        onInvoke: (context, ref) async {
          await ref.read(fileRepositoryProvider).trash(node.id);
          _log.info('Moved to trash',
              fields: {'id': node.id, 'name': node.name});
          _refresh(ref);
        },
      ),
    ];

FileMediaKind _mediaKindFor(String? mime, String name) {
  final m = mime ?? '';
  if (m.startsWith('image/')) return FileMediaKind.image;
  if (m.startsWith('video/')) return FileMediaKind.video;
  if (m.startsWith('audio/')) return FileMediaKind.audio;
  final ext = name.split('.').last.toLowerCase();
  if (['jpg', 'jpeg', 'png', 'gif', 'heic'].contains(ext)) {
    return FileMediaKind.image;
  }
  if (['mp4', 'mov', 'mkv', 'avi'].contains(ext)) return FileMediaKind.video;
  if (['mp3', 'flac', 'wav', 'm4a'].contains(ext)) return FileMediaKind.audio;
  if (['pdf', 'doc', 'docx', 'txt', 'md'].contains(ext)) {
    return FileMediaKind.document;
  }
  return FileMediaKind.none;
}

Future<String?> _promptName(BuildContext context,
    {required String title, String? initial}) async {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = controller.text.trim();
            Navigator.of(context).pop(v.isEmpty ? null : v);
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
