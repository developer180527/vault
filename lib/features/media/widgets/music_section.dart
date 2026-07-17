import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/actions/vault_action.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/models/server_track.dart';
import '../../../core/platform/design/adaptive_icons.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/playback/playable.dart';
import '../../../core/playback/playback_controller.dart';
import '../data/music_library.dart';
import '../data/music_metadata.dart';
import '../data/server_music.dart';
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
/// Hidden when connected: server music arrives via the server's music zone
/// (copy/jobs/uploads), not the local file picker.
final musicServiceActions = <VaultAction>[
  VaultAction(
    id: 'music.add',
    label: 'Add music',
    icon: VaultIcons.add,
    isEnabled: (ref) => !ref.read(musicServerModeProvider),
    onInvoke: (context, ref) => _addMusic(ref),
  ),
];

/// The Music tab. Connected → the SERVER's library, searched and streamed
/// (docs/MUSIC.md). Standalone → local files as before.
class MusicSection extends ConsumerWidget {
  const MusicSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(musicServerModeProvider)) {
      return const _ServerMusicList();
    }
    final tracksAsync = ref.watch(musicTracksProvider);

    // Now-playing controls live in the SHELL (mobile: floating pill; desktop:
    // title bar) so running audio stays visible from every tab.
    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Music unavailable: $e')),
      data: (tracks) => tracks.isEmpty
          ? _AddMusicPrompt(onAdd: () => _addMusic(ref))
          : _TrackList(tracks: tracks),
    );
  }
}

/// Server library: debounced search field + streamed track list with artwork.
class _ServerMusicList extends ConsumerStatefulWidget {
  const _ServerMusicList();

  @override
  ConsumerState<_ServerMusicList> createState() => _ServerMusicListState();
}

class _ServerMusicListState extends ConsumerState<_ServerMusicList> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) ref.read(musicSearchQueryProvider.notifier).set(q);
    });
  }

  Future<void> _play(List<ServerTrack> tracks, int index) async {
    final music = ref.read(vaultClientProvider).music;
    final playables = await serverPlayables(music, tracks);
    if (!mounted) return;
    await ref.read(playbackProvider.notifier).playAudioQueue(playables, index);
    if (mounted) _openPlayer(context);
  }

  @override
  Widget build(BuildContext context) {
    final tracksAsync = ref.watch(serverTracksProvider);
    final headers =
        ref.watch(musicAuthHeadersProvider).asData?.value ?? const {};
    final currentId = ref.watch(playbackProvider).currentAudio?.id;
    final music = ref.read(vaultClientProvider).music;
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _search,
              onChanged: _onQuery,
              decoration: InputDecoration(
                hintText: 'Search your music',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: scheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: tracksAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  Center(child: Text('Server music unavailable: $e')),
              data: (tracks) => tracks.isEmpty
                  ? Center(
                      child: Text(
                        ref.watch(musicSearchQueryProvider).isEmpty
                            ? 'No music on the server yet.\nDrop files into your music folder.'
                            : 'No matches.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      itemCount: tracks.length,
                      itemBuilder: (context, i) {
                        final t = tracks[i];
                        final isCurrent = currentId == t.id;
                        return ListTile(
                          leading: _ServerArt(
                            uri: t.hasArt ? music.artUri(t.id) : null,
                            headers: headers,
                          ),
                          title: Text(t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: isCurrent
                                  ? TextStyle(color: scheme.primary)
                                  : null),
                          subtitle: t.artist.isEmpty
                              ? null
                              : Text(t.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                          trailing: isCurrent
                              ? Icon(Icons.equalizer,
                                  size: 20, color: scheme.primary)
                              : null,
                          onTap: () => _play(tracks, i),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerArt extends StatelessWidget {
  const _ServerArt({required this.uri, required this.headers});

  final Uri? uri;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child:
          Icon(Icons.music_note, size: 20, color: scheme.onSurfaceVariant),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 44,
        child: uri == null || headers.isEmpty
            ? placeholder
            : Image.network(
                uri.toString(),
                headers: headers,
                fit: BoxFit.cover,
                cacheWidth: 132,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
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
