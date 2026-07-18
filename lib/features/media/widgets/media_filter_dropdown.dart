import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/capability/manifest_providers.dart';
import '../../photos/data/backup_engine.dart';
import '../../photos/photos_page.dart';
import '../data/local_media_library.dart';
import '../data/media_providers.dart';
import 'media_trash_sheet.dart';

/// The Media tab's status-bar cluster: backup (when granted) + trash +
/// filter, all icon-only.
class MediaToolbarControls extends ConsumerWidget {
  const MediaToolbarControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Backup is a property of the media library, not its own tab: a cloud
    // button here, the full UI in a sheet. Only members the server grants
    // photos get the button at all.
    final canBackup = ref.watch(manifestProvider
        .select((m) => m.asData?.value.capabilities.containsKey('photos') ??
            false));
    // Arms the automatic run (no-op unless enabled + connected). Lives here
    // because the Media tab is on screen from launch — the old Photos page
    // only armed it if the user happened to visit.
    ref.watch(autoBackupTriggerProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canBackup) ...[
          _BackupButton(scheme: scheme),
          const SizedBox(width: 8),
        ],
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

/// Cloud-backup button: opens the backup sheet; while a run is active it
/// wears a thin progress ring so upload state is visible from the library.
class _BackupButton extends ConsumerWidget {
  const _BackupButton({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(backupEngineProvider);
    final running = state.phase == BackupPhase.scanning ||
        state.phase == BackupPhase.uploading;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: () => openBackupSheet(context),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Tooltip(
          message: running
              ? 'Backing up ${state.done} of ${state.found}'
              : 'Back up to your Vault',
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (running)
                SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: state.found == 0
                        ? null
                        : (state.done / state.found).clamp(0.0, 1.0),
                  ),
                ),
              Icon(
                switch (state.phase) {
                  BackupPhase.done => Icons.cloud_done_outlined,
                  BackupPhase.error => Icons.cloud_off_outlined,
                  _ => Icons.cloud_upload_outlined,
                },
                size: 18,
                color: scheme.onSecondaryContainer,
              ),
            ],
          ),
        ),
      ),
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
