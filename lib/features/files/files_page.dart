import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shell/adaptive_shell.dart';
import '../../shell/widgets/item_context_menu.dart';
import 'server_file_preview.dart';
import 'data/file_browser_controller.dart';
import 'data/upload_queue.dart';
import '../../core/models/file_node.dart';
import 'data/files_view.dart';
import 'file_actions.dart';
import 'widgets/file_row.dart';
import 'widgets/file_tile.dart';

/// The My Files browser. The toolbar (back/forward + directory name) lives in
/// the shell content toolbar; here we render the item grid/list and a
/// Finder-style path bar pinned to the bottom. Right-click / long-press on an
/// item shows item actions; on empty space, folder actions.
class FilesPage extends ConsumerWidget {
  const FilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final childrenAsync = ref.watch(currentChildrenProvider);
    final viewMode = ref.watch(filesViewModeProvider);
    // In-flight / failed uploads for THIS folder ride on top of the server
    // listing as placeholder rows (spinner / error badge). currentChildren is
    // the source of truth once an upload settles.
    final currentId =
        ref.watch(fileBrowserControllerProvider.select((s) => s.currentId));
    final uploadNodes = [
      for (final t in ref.watch(uploadQueueProvider))
        if (t.parentId == currentId) t.toNode(),
    ];

    // Desktop keeps the Finder-style bar at the bottom; on mobile it moves to
    // the top (just under the app bar) where a thumb doesn't cover it and the
    // floating dock can't overlap it.
    final isDesktop = FormFactor.isDesktopOf(context);

    // SafeArea (top only): the mobile shell's toolbar is translucent glass
    // extending over the body — the pinned breadcrumb must start below it.
    return SafeArea(
      bottom: false,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isDesktop) const _PathBar(atTop: true),
        Expanded(
          // Empty-space menu: right-click / long-press anywhere not on an item.
          child: ContextMenuRegion(
            actions: filesServiceActions,
            behavior: HitTestBehavior.translucent,
            child: childrenAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Could not load files: $e')),
              data: (nodes) {
                final merged = [...uploadNodes, ...nodes];
                return merged.isEmpty
                    ? const _EmptyFolder()
                    : viewMode == FilesViewMode.grid
                        ? _grid(context, ref, merged)
                        : _list(context, ref, merged);
              },
            ),
          ),
        ),
        if (isDesktop) const _PathBar(),
      ],
      ),
    );
  }

  Widget _list(BuildContext context, WidgetRef ref, List<FileNode> nodes) {
    return ListView.builder(
      itemCount: nodes.length,
      itemBuilder: (context, i) {
        final node = nodes[i];
        final row = FileRow(node: node, onTap: () => _onTap(context, ref, node));
        // An in-flight/failed upload placeholder has no server id yet, so no
        // file actions apply.
        if (_isPlaceholder(node)) return row;
        return ItemContextMenu(actions: fileItemActions(node), child: row);
      },
    );
  }

  Widget _grid(BuildContext context, WidgetRef ref, List<FileNode> nodes) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.9,
      ),
      itemCount: nodes.length,
      itemBuilder: (context, i) {
        final node = nodes[i];
        final tile =
            FileTile(node: node, onTap: () => _onTap(context, ref, node));
        if (_isPlaceholder(node)) return tile;
        return ItemContextMenu(actions: fileItemActions(node), child: tile);
      },
    );
  }

  static bool _isPlaceholder(FileNode n) =>
      n.syncStatus == SyncStatus.uploading ||
      n.syncStatus == SyncStatus.failed;

  Future<void> _onTap(
      BuildContext context, WidgetRef ref, FileNode node) async {
    if (node.isFolder) {
      ref.read(fileBrowserControllerProvider.notifier).openFolder(node.id);
      return;
    }
    // A still-uploading / failed placeholder isn't a real server file yet.
    if (node.syncStatus == SyncStatus.uploading) return;
    if (node.syncStatus == SyncStatus.failed) {
      ref.read(uploadQueueProvider.notifier).remove(node.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed failed upload “${node.name}”.')),
      );
      return;
    }
    await openServerFileNode(context, ref, node);
  }
}

/// Finder-style path bar showing the full path and letting the user jump to
/// any ancestor. Pinned to the bottom on desktop, or just under the toolbar
/// ([atTop]) on mobile.
class _PathBar extends ConsumerWidget {
  const _PathBar({this.atTop = false});

  final bool atTop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crumbs = ref.watch(breadcrumbProvider).asData?.value ?? const [];
    final controller = ref.read(fileBrowserControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    final edge = BorderSide(color: Theme.of(context).dividerColor);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: atTop ? BorderSide.none : edge,
            bottom: atTop ? edge : BorderSide.none),
      ),
      height: 32,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const SizedBox(width: 8),
            _Segment(
              icon: Icons.home_outlined,
              label: 'My Files',
              isLast: crumbs.isEmpty,
              onTap: () => controller.goTo(null),
            ),
            for (var i = 0; i < crumbs.length; i++) ...[
              Icon(Icons.chevron_right, size: 16, color: scheme.outline),
              _Segment(
                icon: Icons.folder_outlined,
                label: crumbs[i].name,
                isLast: i == crumbs.length - 1,
                onTap: () => controller.goTo(crumbs[i].id),
              ),
            ],
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.icon,
    required this.label,
    required this.isLast,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: isLast ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            Icon(icon,
                size: 14,
                color: isLast ? scheme.onSurface : scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: isLast ? scheme.onSurface : scheme.onSurfaceVariant,
                    fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyFolder extends StatelessWidget {
  const _EmptyFolder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Fill the area so empty-space right-click works even when there are no
    // items to hit.
    return SizedBox.expand(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined,
                size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('This folder is empty', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text('Right-click to add files or a folder',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}
