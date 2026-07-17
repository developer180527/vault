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

/// The Music tab. Connected → the server's music service in three sections
/// (Home / Search / Library, Instagram-profile style). Standalone → local
/// files as before.
class MusicSection extends ConsumerWidget {
  const MusicSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(musicServerModeProvider)) {
      return const _ServerMusic();
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

/// Connected music, three swipeable sections under one slim tab strip:
///
///  - **Home**: browse the shared catalog (albums / recommendations / pinned
///    music land here later).
///  - **Search**: the search field + catalog results — search UI lives ONLY
///    here, not floating over every view.
///  - **Library**: the user's playlists (drill-in) and their personal music.
class _ServerMusic extends ConsumerStatefulWidget {
  const _ServerMusic();

  @override
  ConsumerState<_ServerMusic> createState() => _ServerMusicState();
}

class _ServerMusicState extends ConsumerState<_ServerMusic> {
  /// Library drill-in: non-null while a playlist's tracks are open.
  Playlist? _openPlaylist;

  /// Whether the last catalog play started from the Search section — the
  /// listen event's `library` vs `search` tag.
  bool _playingFromSearch = false;

  // ---- playback ----

  /// Play [tracks] starting at [index]. Catalog-backed queues report a listen
  /// event tagged with where playback started (the recommender's raw food);
  /// the personal zone streams the per-user endpoints and reports nothing.
  Future<void> _play(
    List<ServerTrack> tracks,
    int index, {
    required MusicSource source,
  }) async {
    final music = ref.read(vaultClientProvider).music;
    final personal = source is PersonalSource;
    final playables = personal
        ? await serverPlayables(music, tracks)
        : await catalogPlayables(music, tracks);
    if (!mounted) return;
    await ref.read(playbackProvider.notifier).playAudioQueue(playables, index);
    if (!personal) {
      final query = source is CatalogSource && _playingFromSearch
          ? ref.read(musicSearchQueryProvider)
          : '';
      unawaited(
        music.reportListen(
          tracks[index].id,
          source: listenSourceFor(source, query),
        ),
      );
    }
    if (mounted) _openPlayer(context);
  }

  // ---- playlist management ----

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
    if (mounted) setState(() => _openPlaylist = created);
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
    ref.invalidate(playlistsProvider);
    if (mounted && _openPlaylist?.id == p.id) {
      setState(() => _openPlaylist = null);
    }
  }

  /// Long-press a catalog track → add-to-playlist sheet; inside a playlist →
  /// remove it from that playlist.
  Future<void> _trackMenu(ServerTrack t, {Playlist? inPlaylist}) async {
    final music = ref.read(vaultClientProvider).music;
    if (inPlaylist != null) {
      await music.removeFromPlaylist(inPlaylist.id, t.id);
      ref
        ..invalidate(playlistTracksProvider(inPlaylist.id))
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
    ref
      ..invalidate(playlistTracksProvider(target.id))
      ..invalidate(playlistsProvider);
  }

  /// Desktop right-click on a catalog/playlist track row.
  void _trackContextMenu(
    ServerTrack t,
    Offset position, {
    Playlist? inPlaylist,
  }) {
    showContextMenu(
      context: context,
      ref: ref,
      globalPosition: position,
      actions: [
        VaultAction(
          id: 'music.playlist.toggle',
          label: inPlaylist != null
              ? 'Remove from playlist'
              : 'Add to playlist…',
          icon: inPlaylist != null ? VaultIcons.trash : VaultIcons.add,
          onInvoke: (_, _) => _trackMenu(t, inPlaylist: inPlaylist),
        ),
      ],
    );
  }

  // ---- sections ----

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            // Slim section strip — the page's inner navigation, browser-tab
            // style. Swiping between sections works via the TabBarView.
            TabBar(
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.label,
              labelColor: scheme.primary,
              unselectedLabelColor: scheme.onSurfaceVariant,
              tabs: const [
                Tab(height: 44, icon: Icon(Icons.home_outlined, size: 20)),
                Tab(height: 44, icon: Icon(Icons.search, size: 20)),
                Tab(
                  height: 44,
                  icon: Icon(Icons.library_music_outlined, size: 20),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildHome(),
                  _SearchSection(
                    onPlay: (tracks, i) {
                      _playingFromSearch = true;
                      _play(tracks, i, source: const CatalogSource());
                    },
                    onTrackMenu: (t) => _trackMenu(t),
                    onTrackContextMenu: (t, pos) => _trackContextMenu(t, pos),
                  ),
                  _buildLibrary(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHome() {
    final tracksAsync = ref.watch(catalogTracksProvider);
    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Catalog unavailable: $e')),
      data: (tracks) => tracks.isEmpty
          ? const _EmptyNote(
              'The catalog is empty.\nThe admin loads music into it on the server.',
            )
          : _ServerTrackList(
              tracks: tracks,
              catalogArt: true,
              onPlay: (t, i) {
                _playingFromSearch = false;
                _play(t, i, source: const CatalogSource());
              },
              onLongPress: (t) => _trackMenu(t),
              onSecondaryTap: (t, pos) => _trackContextMenu(t, pos),
            ),
    );
  }

  Widget _buildLibrary() {
    final open = _openPlaylist;
    if (open != null) return _buildPlaylistDetail(open);

    final playlists =
        ref.watch(playlistsProvider).asData?.value ?? const <Playlist>[];
    final personalAsync = ref.watch(personalTracksProvider);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      children: [
        _SectionHeader(
          'Playlists',
          trailing: TextButton.icon(
            onPressed: _newPlaylist,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New'),
          ),
        ),
        if (playlists.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Text(
              'No playlists yet.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        for (final p in playlists)
          GestureDetector(
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
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.surfaceContainerHighest,
                child: Icon(
                  Icons.queue_music,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              title: Text(p.name),
              subtitle: Text('${p.trackCount} tracks'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => setState(() => _openPlaylist = p),
              onLongPress: () => _deletePlaylist(p),
            ),
          ),
        _SectionHeader('My music'),
        personalAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(20),
            child: Text('My music unavailable: $e'),
          ),
          data: (tracks) => tracks.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: Text(
                    'No music in your zone yet.\nDrop files into your music folder.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : _ServerTrackList(
                  tracks: tracks,
                  catalogArt: false,
                  shrinkWrap: true,
                  onPlay: (t, i) => _play(t, i, source: const PersonalSource()),
                ),
        ),
        const SizedBox(height: 120), // clear the floating dock
      ],
    );
  }

  Widget _buildPlaylistDetail(Playlist p) {
    final tracksAsync = ref.watch(playlistTracksProvider(p.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Back to Library',
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: () => setState(() => _openPlaylist = null),
            ),
            Expanded(
              child: Text(
                p.name,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Delete playlist',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deletePlaylist(p),
            ),
          ],
        ),
        Expanded(
          child: tracksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Playlist unavailable: $e')),
            data: (tracks) => tracks.isEmpty
                ? const _EmptyNote(
                    'This playlist is empty.\nLong-press a track in Home or Search to add it.',
                  )
                : _ServerTrackList(
                    tracks: tracks,
                    catalogArt: true,
                    onPlay: (t, i) => _play(t, i, source: PlaylistSource(p)),
                    onLongPress: (t) => _trackMenu(t, inPlaylist: p),
                    onSecondaryTap: (t, pos) =>
                        _trackContextMenu(t, pos, inPlaylist: p),
                  ),
          ),
        ),
      ],
    );
  }
}

/// The Search section: field + results. Kept stateful and self-contained so
/// typing only rebuilds THIS section — and the field survives section swipes.
class _SearchSection extends ConsumerStatefulWidget {
  const _SearchSection({
    required this.onPlay,
    required this.onTrackMenu,
    required this.onTrackContextMenu,
  });

  final void Function(List<ServerTrack> tracks, int index) onPlay;
  final void Function(ServerTrack) onTrackMenu;
  final void Function(ServerTrack, Offset) onTrackContextMenu;

  @override
  ConsumerState<_SearchSection> createState() => _SearchSectionState();
}

class _SearchSectionState extends ConsumerState<_SearchSection> {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resultsAsync = ref.watch(catalogSearchProvider);
    final query = ref.watch(musicSearchQueryProvider).trim();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: TextField(
            controller: _search,
            onChanged: _onQuery,
            decoration: InputDecoration(
              hintText: 'Search the catalog',
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
          child: query.isEmpty
              ? const _EmptyNote(
                  'Search the shared catalog\nby title, artist, or album.',
                )
              : resultsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Search failed: $e')),
                  data: (tracks) => tracks.isEmpty
                      ? const _EmptyNote('No matches.')
                      : _ServerTrackList(
                          tracks: tracks,
                          catalogArt: true,
                          onPlay: widget.onPlay,
                          onLongPress: widget.onTrackMenu,
                          onSecondaryTap: widget.onTrackContextMenu,
                        ),
                ),
        ),
      ],
    );
  }
}

/// Shared server-track list: artwork rows, now-playing highlight, optional
/// long-press / right-click hooks. Used by all three sections.
class _ServerTrackList extends ConsumerWidget {
  const _ServerTrackList({
    required this.tracks,
    required this.catalogArt,
    required this.onPlay,
    this.onLongPress,
    this.onSecondaryTap,
    this.shrinkWrap = false,
  });

  final List<ServerTrack> tracks;

  /// true → shared catalog art endpoints; false → personal-zone endpoints.
  final bool catalogArt;
  final void Function(List<ServerTrack>, int) onPlay;
  final void Function(ServerTrack)? onLongPress;
  final void Function(ServerTrack, Offset)? onSecondaryTap;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select: highlight tracking needs only the current track ID — the whole
    // list must not rebuild on unrelated playback events.
    final currentId = ref.watch(
      playbackProvider.select((s) => s.currentAudio?.id),
    );
    final music = ref.read(vaultClientProvider).music;
    final scheme = Theme.of(context).colorScheme;

    return ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        final isCurrent = currentId == t.id;
        final tile = ListTile(
          leading: _ServerArt(
            uri: !t.hasArt
                ? null
                : catalogArt
                ? music.catalogArtUri(t.id)
                : music.artUri(t.id),
          ),
          title: Text(
            t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: isCurrent ? TextStyle(color: scheme.primary) : null,
          ),
          subtitle: t.artist.isEmpty
              ? null
              : Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: isCurrent
              ? Icon(Icons.equalizer, size: 20, color: scheme.primary)
              : null,
          onTap: () => onPlay(tracks, i),
          onLongPress: onLongPress == null ? null : () => onLongPress!(t),
        );
        if (onSecondaryTap == null) return tile;
        return GestureDetector(
          onSecondaryTapUp: (d) => onSecondaryTap!(t, d.globalPosition),
          child: tile,
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ServerArt extends ConsumerWidget {
  const _ServerArt({required this.uri});

  final Uri? uri;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, size: 20, color: scheme.onSurfaceVariant),
    );
    // Content cache: disk-hit art paints in the same frame as the row —
    // scrolling a list you've seen before never shows placeholder pop-in.
    final bytes = uri == null
        ? null
        : ref.watch(artBytesProvider(uri.toString())).asData?.value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 44,
        child: bytes == null
            ? placeholder
            : Image.memory(
                bytes,
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
