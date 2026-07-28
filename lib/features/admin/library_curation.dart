import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/client/vault_client.dart';
import '../media/data/server_music.dart';
import '../movies/data/server_movies.dart';
import 'edit_metadata_sheet.dart';

/// The Library half of the Administrative service: browse what's in the shared
/// catalog and fix its metadata/artwork. Read straight from the same providers
/// the member UI uses, so a change made here shows up everywhere at once.
class LibraryCuration extends ConsumerStatefulWidget {
  const LibraryCuration({super.key});

  @override
  ConsumerState<LibraryCuration> createState() => _LibraryCurationState();
}

class _LibraryCurationState extends ConsumerState<LibraryCuration> {
  final _search = TextEditingController();
  String _query = '';
  bool _movies = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Row(
            children: [
              SegmentedButton<bool>(
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('Music'),
                    icon: Icon(Icons.library_music_outlined, size: 17),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Movies'),
                    icon: Icon(Icons.movie_outlined, size: 17),
                  ),
                ],
                selected: {_movies},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _movies = s.first),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (q) => setState(() => _query = q.trim()),
                  decoration: InputDecoration(
                    hintText: _movies ? 'Filter movies' : 'Filter tracks',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _movies ? _MovieList(query: _query) : _TrackList(query: _query),
        ),
      ],
    );
  }
}

class _TrackList extends ConsumerWidget {
  const _TrackList({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(catalogTracksProvider);
    return tracks.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Message('Could not load the catalog.\n$e'),
      data: (all) {
        final list = _filter(all, query,
            (t) => '${t.title} ${t.artist} ${t.album}'.toLowerCase());
        if (list.isEmpty) {
          return const _Message('Nothing here yet. Upload music to get started.');
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 120),
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
          itemBuilder: (context, i) {
            final t = list[i];
            return ListTile(
              leading: _Art(
                uri: t.hasArt
                    ? ref
                        .read(vaultClientProvider)
                        .music
                        .catalogArtUri(t.id, version: t.artVersion)
                        .toString()
                    : null,
                fallback: Icons.music_note,
              ),
              title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  if (t.artist.isNotEmpty) t.artist,
                  if (t.album.isNotEmpty) t.album,
                  if (t.year != 0) '${t.year}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () => openTrackEditor(context, t),
            );
          },
        );
      },
    );
  }
}

class _MovieList extends ConsumerWidget {
  const _MovieList({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movies = ref.watch(movieCatalogProvider);
    return movies.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Message('Could not load the movie library.\n$e'),
      data: (all) {
        final list = _filter(
            all, query, (m) => '${m.title} ${m.series}'.toLowerCase());
        if (list.isEmpty) {
          return const _Message('Nothing here yet. Upload movies to get started.');
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 120),
          itemCount: list.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
          itemBuilder: (context, i) {
            final m = list[i];
            return ListTile(
              leading: _Art(
                uri: m.hasArt
                    ? ref
                        .read(vaultClientProvider)
                        .movies
                        .artUri(m.id, version: m.artVersion)
                        .toString()
                    : null,
                fallback: Icons.movie_outlined,
              ),
              title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                m.subtitle.isEmpty
                    ? (m.isEpisode ? 'Episode' : 'Movie')
                    : m.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () => openMovieEditor(context, m),
            );
          },
        );
      },
    );
  }
}

List<T> _filter<T>(List<T> all, String query, String Function(T) text) {
  if (query.isEmpty) return all;
  final q = query.toLowerCase();
  return [
    for (final x in all)
      if (text(x).contains(q)) x,
  ];
}

/// Thumbnail for a row, fetched through the shared content cache so the
/// curation list reuses art the rest of the app already has on disk.
class _Art extends ConsumerWidget {
  const _Art({required this.uri, required this.fallback});
  final String? uri;
  final IconData fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bytes =
        uri == null ? null : ref.watch(artBytesProvider(uri!)).asData?.value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 44,
        child: bytes != null
            ? Image.memory(bytes,
                fit: BoxFit.cover, cacheWidth: 132, gaplessPlayback: true)
            : ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(fallback, size: 18, color: scheme.onSurfaceVariant),
              ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
