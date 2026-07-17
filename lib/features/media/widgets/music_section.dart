import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/actions/vault_action.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/server_track.dart';
import '../../../core/platform/design/adaptive_icons.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/playback/playable.dart';
import '../../../core/playback/playback_controller.dart';
import '../../../shell/widgets/context_menu.dart';
import '../data/music_library.dart';
import '../data/music_metadata.dart';
import '../data/server_music.dart';
import '../music_player_page.dart';

/// Maps the user's tracks (+ read tags) into audio [Playable]s for the
/// centralized player. Local files; server music will just produce network
/// Playables with the same shape.
List<Playable> playablesFor(WidgetRef ref, List<MusicTrack> tracks) => [
  for (final t in tracks) _playable(metadataFor(ref, t.path), t),
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

/// Connected music: the SHARED catalog by default, with the personal zone and
/// the user's playlists one chip away. Debounced search + streamed artwork.
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
    final source = ref.read(musicSourceProvider);
    final personal = source is PersonalSource;
    final playables = personal
        ? await serverPlayables(music, tracks)
        : await catalogPlayables(music, tracks);
    if (!mounted) return;
    await ref.read(playbackProvider.notifier).playAudioQueue(playables, index);
    if (!personal) {
      // Raw listen event for the future recommender — fire and forget.
      unawaited(
        music.reportListen(
          tracks[index].id,
          source: listenSourceFor(source, ref.read(musicSearchQueryProvider)),
        ),
      );
    }
    if (mounted) _openPlayer(context);
  }

  Future<void> _newPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    final created = await ref
        .read(vaultClientProvider)
        .music
        .createPlaylist(trimmed);
    ref.invalidate(playlistsProvider);
    ref.read(musicSourceProvider.notifier).set(PlaylistSource(created));
  }

  /// Long-press on a catalog track → add to a playlist; on a playlist track →
  /// remove (or delete the playlist from its chip's long-press).
  Future<void> _trackMenu(ServerTrack t) async {
    final source = ref.read(musicSourceProvider);
    final music = ref.read(vaultClientProvider).music;
    if (source is PlaylistSource) {
      await music.removeFromPlaylist(source.playlist.id, t.id);
      ref
        ..invalidate(sourceTracksProvider)
        ..invalidate(playlistsProvider);
      return;
    }
    final playlists = await ref
        .read(playlistsProvider.future)
        .catchError((_) => <Playlist>[]);
    if (!mounted) return;
    final target = await showModalBottomSheet<Playlist>(
      context: context,
      // Root navigator: the sheet must rise ABOVE the shell chrome (glass
      // dock + mini player), not underneath it inside the tab's navigator.
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Add "${t.title}" to playlist',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              dense: true,
            ),
            for (final p in playlists)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(p.name),
                subtitle: Text('${p.trackCount} tracks'),
                onTap: () => Navigator.pop(context, p),
              ),
            if (playlists.isEmpty)
              const ListTile(
                title: Text('No playlists yet — create one first.'),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;
    await music.addToPlaylist(target.id, t.id);
    ref.invalidate(playlistsProvider);
  }

  /// Desktop right-click on a catalog/playlist track row.
  void _trackContextMenu(ServerTrack t, Offset position) {
    final source = ref.read(musicSourceProvider);
    showContextMenu(
      context: context,
      ref: ref,
      globalPosition: position,
      actions: [
        VaultAction(
          id: 'music.playlist.toggle',
          label: source is PlaylistSource
              ? 'Remove from playlist'
              : 'Add to playlist…',
          icon: source is PlaylistSource ? VaultIcons.trash : VaultIcons.add,
          onInvoke: (_, _) => _trackMenu(t),
        ),
      ],
    );
  }

  Future<void> _deletePlaylist(Playlist p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${p.name}"?'),
        content: const Text('The music itself stays in the catalog.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(vaultClientProvider).music.deletePlaylist(p.id);
    ref.read(musicSourceProvider.notifier).set(const CatalogSource());
    ref.invalidate(playlistsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(musicSourceProvider);
    final tracksAsync = ref.watch(sourceTracksProvider);
    final playlists =
        ref.watch(playlistsProvider).asData?.value ?? const <Playlist>[];
    final headers =
        ref.watch(musicAuthHeadersProvider).asData?.value ?? const {};
    // select: highlight tracking needs only the current track ID — the
    // whole list must not rebuild on unrelated playback events.
    final currentId = ref.watch(
      playbackProvider.select((s) => s.currentAudio?.id),
    );
    final music = ref.read(vaultClientProvider).music;
    final scheme = Theme.of(context).colorScheme;
    final personal = source is PersonalSource;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _search,
              onChanged: _onQuery,
              decoration: InputDecoration(
                hintText: personal ? 'Search your music' : 'Search the catalog',
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
          // Source chips: catalog / personal zone / playlists / new playlist.
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                ChoiceChip(
                  label: const Text('Catalog'),
                  selected: source is CatalogSource,
                  onSelected: (_) => ref
                      .read(musicSourceProvider.notifier)
                      .set(const CatalogSource()),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('My music'),
                  selected: personal,
                  onSelected: (_) => ref
                      .read(musicSourceProvider.notifier)
                      .set(const PersonalSource()),
                ),
                for (final p in playlists) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onLongPress: () => _deletePlaylist(p),
                    onSecondaryTapUp: (d) => showContextMenu(
                      context: context,
                      ref: ref,
                      globalPosition: d.globalPosition,
                      actions: [
                        VaultAction(
                          id: 'music.playlist.delete',
                          label: 'Delete playlist',
                          icon: VaultIcons.trash,
                          onInvoke: (_, _) => _deletePlaylist(p),
                        ),
                      ],
                    ),
                    child: ChoiceChip(
                      label: Text(p.name),
                      avatar: const Icon(Icons.queue_music, size: 16),
                      selected:
                          source is PlaylistSource &&
                          source.playlist.id == p.id,
                      onSelected: (_) => ref
                          .read(musicSourceProvider.notifier)
                          .set(PlaylistSource(p)),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                ActionChip(
                  label: const Text('New playlist'),
                  avatar: const Icon(Icons.add, size: 16),
                  onPressed: _newPlaylist,
                ),
              ],
            ),
          ),
          Expanded(
            child: tracksAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  Center(child: Text('Server music unavailable: $e')),
              data: (tracks) => tracks.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _emptyText(
                            source,
                            ref.watch(musicSearchQueryProvider).isEmpty,
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: tracks.length,
                      itemBuilder: (context, i) {
                        final t = tracks[i];
                        final isCurrent = currentId == t.id;
                        final tile = ListTile(
                          leading: _ServerArt(
                            uri: !t.hasArt
                                ? null
                                : personal
                                ? music.artUri(t.id)
                                : music.catalogArtUri(t.id),
                            headers: headers,
                          ),
                          title: Text(
                            t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: isCurrent
                                ? TextStyle(color: scheme.primary)
                                : null,
                          ),
                          subtitle: t.artist.isEmpty
                              ? null
                              : Text(
                                  t.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: isCurrent
                              ? Icon(
                                  Icons.equalizer,
                                  size: 20,
                                  color: scheme.primary,
                                )
                              : null,
                          onTap: () => _play(tracks, i),
                          // Playlists reference catalog UUIDs, so only
                          // catalog-backed rows get the long-press menu
                          // (mobile) / right-click menu (desktop).
                          onLongPress: personal ? null : () => _trackMenu(t),
                        );
                        if (personal) return tile;
                        return GestureDetector(
                          onSecondaryTapUp: (d) =>
                              _trackContextMenu(t, d.globalPosition),
                          child: tile,
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

String _emptyText(MusicSource source, bool queryEmpty) {
  if (!queryEmpty) return 'No matches.';
  return switch (source) {
    CatalogSource() =>
      'The catalog is empty.\nThe admin loads music into it on the server.',
    PersonalSource() =>
      'No music in your zone yet.\nDrop files into your music folder.',
    PlaylistSource() =>
      'This playlist is empty.\nLong-press a catalog track to add it.',
  };
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
      child: Icon(Icons.music_note, size: 20, color: scheme.onSurfaceVariant),
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
            Text(
              'Add your music',
              style: Theme.of(context).textTheme.titleMedium,
            ),
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
              icon: Icon(
                isDesktopPlatform
                    ? Icons.folder_open
                    : Icons.library_add_outlined,
              ),
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
    // select: highlight tracking needs only the current track ID — the
    // whole list must not rebuild on unrelated playback events.
    final currentId = ref.watch(
      playbackProvider.select((s) => s.currentAudio?.id),
    );
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
                  ? Image.memory(
                      meta.art!,
                      fit: BoxFit.cover,
                      cacheWidth: 132,
                      gaplessPlayback: true,
                    )
                  : ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.music_note,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          title: Text(
            meta.title ?? track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: isCurrent ? TextStyle(color: scheme.primary) : null,
          ),
          subtitle: meta.artist == null
              ? null
              : Text(
                  meta.artist!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => const MusicPlayerPage(),
    ),
  );
}
