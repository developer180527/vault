import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../../../core/auth/local_auth_gate.dart';
import '../data/media_trash.dart';

/// Opens the media trash — behind the device-local auth gate (Face ID /
/// biometrics / device credential). Bounces silently if the check fails.
Future<void> openMediaTrash(BuildContext context, WidgetRef ref) async {
  final ok = await ref
      .read(localAuthGateProvider)
      .authenticate(reason: 'Unlock the media trash');
  if (!ok || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    // Root navigator: rises above the shell chrome (dock + mini player).
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _TrashSheet(),
  );
}

class _TrashSheet extends ConsumerWidget {
  const _TrashSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trashed = ref.watch(trashedMediaProvider);
    final scheme = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              'Recently deleted',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              "They'll be permanently deleted after 30 days.",
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: trashed.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Trash unavailable: $e')),
              data: (items) => items.isEmpty
                  ? Center(
                      child: Text(
                        'Trash is empty.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: items.length,
                      itemBuilder: (context, i) => _TrashRow(item: items[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrashRow extends ConsumerWidget {
  const _TrashRow({required this.item});

  final TrashedMedia item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isVideo = item.asset.type == AssetType.video;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Image(
            image: AssetEntityImageProvider(
              item.asset,
              isOriginal: false,
              thumbnailSize: const ThumbnailSize.square(144),
            ),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Icon(
                isVideo ? Icons.videocam : Icons.image,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
      title: Text(isVideo ? 'Video' : 'Photo'),
      subtitle: Text(
        item.daysLeft <= 0 ? 'Deleting soon' : '${item.daysLeft} days left',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Restore',
            icon: const Icon(Icons.restore),
            onPressed: () =>
                ref.read(mediaTrashProvider.notifier).restore(item.entry.id),
          ),
          IconButton(
            tooltip: 'Delete now',
            icon: Icon(Icons.delete_forever, color: scheme.error),
            // The OS shows its own confirmation dialog for the real delete —
            // no extra in-app confirm needed on top.
            onPressed: () => ref
                .read(mediaTrashProvider.notifier)
                .deleteForever([item.entry.id]),
          ),
        ],
      ),
    );
  }
}
