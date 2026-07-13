import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_media_library.dart';
import '../data/media_providers.dart';

/// Pill-shaped dropdown for the media filter (All / Photos / Videos / Music).
/// Lives in the tab's status-bar slot (where the background-work cloud used to
/// be), replacing the floating bottom pill.
class MediaFilterDropdown extends ConsumerWidget {
  const MediaFilterDropdown({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(mediaFilterProvider);
    final scheme = Theme.of(context).colorScheme;

    return PopupMenuButton<MediaFilter>(
      tooltip: 'Filter',
      position: PopupMenuPosition.under,
      onSelected: (f) => ref.read(mediaFilterProvider.notifier).set(f),
      itemBuilder: (context) => [
        for (final f in MediaFilter.values)
          PopupMenuItem(
            value: f,
            child: Row(
              children: [
                Icon(f.icon,
                    size: 20,
                    color: f == filter ? scheme.primary : null),
                const SizedBox(width: 12),
                Text(f.label),
                if (f == filter) ...[
                  const Spacer(),
                  Icon(Icons.check, size: 18, color: scheme.primary),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(filter.icon, size: 18, color: scheme.onSecondaryContainer),
            const SizedBox(width: 6),
            Text(filter.label,
                style: TextStyle(color: scheme.onSecondaryContainer)),
            Icon(Icons.arrow_drop_down, color: scheme.onSecondaryContainer),
          ],
        ),
      ),
    );
  }
}
