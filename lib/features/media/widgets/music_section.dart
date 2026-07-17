import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/actions/vault_action.dart';
import '../../../core/platform/design/adaptive_icons.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/playback/playable.dart';
import '../../../core/playback/playback_controller.dart';
import '../data/music_library.dart';
import '../data/music_metadata.dart';
import '../music_player_page.dart';

/// Maps the user's tracks (+ read tags) into audio [Playable]s for the
/// centralized player. Local files; server music will just produce network
/// Playables with the same shape.
List<Playable> playablesFor(WidgetRef ref, List<MusicTrack> tracks) => [
      for (final t in tracks)
        _playable(metadataFor(ref, t.path), t),
    ];

Playable _playable(TrackMetadata m, MusicTrack t) => Playable(
      id: t.path,
      kind: PlayableKind.audio,
      uri: Uri.file(t.path),
      title: m.title ?? t.title,
      subtitle: m.artist ?? '',
      album: m.album ?? '',
      artwork: m.art,
    );

Future<void> _addMusic(WidgetRef ref) async {
  final added = await ref.read(musicLibraryProvider).addMusic();
  if (added) ref.read(musicRevisionProvider.notifier).bump();
}

/// Toolbar/palette actions for the Music service — "Add music" lives in the
/// app bar (top-right, next to the tab title) rather than inside the list.
final musicServiceActions = <VaultAction>[
  VaultAction(
    id: 'music.add',
    label: 'Add music',
    icon: VaultIcons.add,
    onInvoke: (context, ref) => _addMusic(ref),
  ),
];

/// The Music tab: lists the user's added tracks with a mini-player, or prompts
/// to add music the first time.
class MusicSection extends ConsumerWidget {
  const MusicSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(musicTracksProvider);

    // Now-playing controls live in the SHELL (mobile: floating pill; desktop:
    // sidebar card) so running audio stays visible from every tab — a
    // tab-local bar here left desktop audio uncontrollable elsewhere.
    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Music unavailable: $e')),
      data: (tracks) => tracks.isEmpty
          ? _AddMusicPrompt(onAdd: () => _addMusic(ref))
          : _TrackList(tracks: tracks),
    );
  }
}

class _AddMusicPrompt extends StatelessWidget {
  const _AddMusicPrompt({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music_outlined, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            Text('Add your music',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              isDesktopPlatform
                  ? 'Choose a folder and Vault will list the audio files inside.'
                  : 'Pick the audio files you want to listen to.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: Icon(isDesktopPlatform
                  ? Icons.folder_open
                  : Icons.library_add_outlined),
              label: Text(isDesktopPlatform ? 'Choose folder' : 'Add music'),
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackList extends ConsumerWidget {
  const _TrackList({required this.tracks});

  final List<MusicTrack> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentId = ref.watch(playbackProvider).currentAudio?.id;
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final track = tracks[i];
        final meta = metadataFor(ref, track.path);
        final isCurrent = currentId == track.path;
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 44,
              height: 44,
              child: meta.art != null
                  // cacheWidth: decode a thumbnail, not the full cover.
                  ? Image.memory(meta.art!,
                      fit: BoxFit.cover, cacheWidth: 132, gaplessPlayback: true)
                  : ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.music_note,
                          size: 20, color: scheme.onSurfaceVariant),
                    ),
            ),
          ),
          title: Text(meta.title ?? track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isCurrent ? TextStyle(color: scheme.primary) : null),
          subtitle: meta.artist == null
              ? null
              : Text(meta.artist!,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: isCurrent
              ? Icon(Icons.equalizer, size: 20, color: scheme.primary)
              : null,
          onTap: () {
            ref
                .read(playbackProvider.notifier)
                .playAudioQueue(playablesFor(ref, tracks), i);
            _openPlayer(context);
          },
        );
      },
    );
  }
}

void _openPlayer(BuildContext context) {
  // Root navigator so the full-screen player covers the whole shell (app bar +
  // bottom nav), not just the tab's body.
  Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => const MusicPlayerPage(),
  ));
}
