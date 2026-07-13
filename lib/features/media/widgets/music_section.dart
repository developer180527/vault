import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/platform/platform_info.dart';
import '../data/music_library.dart';
import '../data/music_player_controller.dart';
import '../music_player_page.dart';

/// The Music view inside the Media tab: lists the user's added tracks with a
/// mini-player, or prompts to add music the first time.
class MusicSection extends ConsumerWidget {
  const MusicSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(musicTracksProvider);
    final playerState = ref.watch(musicPlayerProvider);

    Future<void> addMusic() async {
      final added = await ref.read(musicLibraryProvider).addMusic();
      if (added) {
        ref.read(musicRevisionProvider.notifier).bump();
      }
    }

    return Column(
      children: [
        Expanded(
          child: tracksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Music unavailable: $e')),
            data: (tracks) => tracks.isEmpty
                ? _AddMusicPrompt(onAdd: addMusic)
                : _TrackList(tracks: tracks, onAdd: addMusic),
          ),
        ),
        if (playerState.current != null) const _MiniPlayer(),
      ],
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
  const _TrackList({required this.tracks, required this.onAdd});

  final List<MusicTrack> tracks;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerState = ref.watch(musicPlayerProvider);
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add more'),
              onPressed: onAdd,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) {
              final track = tracks[i];
              final isCurrent = playerState.current?.id == track.id;
              return ListTile(
                leading: Icon(
                  isCurrent ? Icons.equalizer : Icons.music_note,
                  color:
                      isCurrent ? Theme.of(context).colorScheme.primary : null,
                ),
                title: Text(track.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                  ref
                      .read(musicPlayerProvider.notifier)
                      .playQueue(tracks, i);
                  _openPlayer(context);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

void _openPlayer(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => const MusicPlayerPage(),
  ));
}

/// Compact now-playing bar that opens the full-screen player on tap.
class _MiniPlayer extends ConsumerWidget {
  const _MiniPlayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(musicPlayerProvider);
    final controller = ref.read(musicPlayerProvider.notifier);
    final track = state.current;
    if (track == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => _openPlayer(context),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.music_note, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(track.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                StreamBuilder<PlayerState>(
                  stream: controller.player.playerStateStream,
                  builder: (context, snapshot) {
                    final playing = snapshot.data?.playing ?? false;
                    return IconButton(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: controller.togglePlay,
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: controller.next,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
