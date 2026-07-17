import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_media_library.dart';
import '../data/media_providers.dart';
import 'media_trash_sheet.dart';

/// The Media tab's status-bar cluster: trash + filter, both icon-only.
class MediaToolbarControls extends ConsumerWidget {
  const MediaToolbarControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Trash: gated behind device-local auth (Face ID / biometrics /
        // passcode) — deleted media is still media.
        InkWell(
          customBorder: const CircleBorder(),
          onTap: () => openMediaTrash(context, ref),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              shape: BoxShape.circle,
            ),
            child: Tooltip(
              message: 'Recently deleted',
              child: Icon(
                Icons.delete_outline,
                size: 18,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        const MediaFilterDropdown(),
      ],
    );
  }
}

/// Icon-only filter button for the media toolbar (All / Photos / Videos).
/// Collapsed it shows just the active filter's icon; the opened menu shows
/// icon + name for every choice. Lives in the tab's status-bar slot.
class MediaFilterDropdown extends ConsumerWidget {
  const MediaFilterDropdown({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(mediaFilterProvider);
    final scheme = Theme.of(context).colorScheme;

    return PopupMenuButton<MediaFilter>(
      // Tooltip doubles as the a11y label — icon-only controls still need a
      // name for screen readers and desktop hover.
      tooltip: 'Filter: ${filter.label}',
      position: PopupMenuPosition.under,
      onSelected: (f) => ref.read(mediaFilterProvider.notifier).set(f),
      itemBuilder: (context) => [
        for (final f in MediaFilter.values)
          PopupMenuItem(
            value: f,
            child: Row(
              children: [
                Icon(
                  f.icon,
                  size: 20,
                  color: f == filter ? scheme.primary : null,
                ),
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
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(filter.icon, size: 18, color: scheme.onSecondaryContainer),
      ),
    );
  }
}
