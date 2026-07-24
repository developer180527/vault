import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/server_movie.dart';
import 'data/server_movies.dart';
import 'movie_detail_page.dart';
import 'widgets/poster.dart';

/// The Movies tab: a search field, a Continue Watching shelf, then the poster
/// grid. Fully responsive — the grid reflows from 3 columns on a phone to as
/// many as fit a desktop window.
class MoviesSection extends ConsumerStatefulWidget {
  const MoviesSection({super.key});

  @override
  ConsumerState<MoviesSection> createState() => _MoviesSectionState();
}

class _MoviesSectionState extends ConsumerState<MoviesSection> {
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
      if (mounted) ref.read(movieSearchQueryProvider.notifier).set(q);
    });
  }

  void _open(ServerMovie m) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => MovieDetailPage(movieId: m.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = ref.watch(movieSearchQueryProvider).trim();
    final searching = query.isNotEmpty;
    final catalog = ref.watch(movieCatalogProvider);
    final continueList =
        ref.watch(continueWatchingProvider).asData?.value ?? const [];

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: _onQuery,
              decoration: InputDecoration(
                hintText: 'Search movies & shows',
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
            child: searching
                ? _SearchResults(onOpen: _open)
                : catalog.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) =>
                        Center(child: Text('Catalog unavailable: $e')),
                    data: (movies) => movies.isEmpty
                        ? const _EmptyNote(
                            'No movies yet.\nThe admin loads them into the catalog on the server.',
                          )
                        : CustomScrollView(
                            slivers: [
                              if (continueList.isNotEmpty) ...[
                                const _Header('Continue Watching'),
                                SliverToBoxAdapter(
                                  child: _ContinueShelf(
                                      movies: continueList, onOpen: _open),
                                ),
                              ],
                              const _Header('All'),
                              _PosterGrid(movies: movies, onOpen: _open),
                              const SliverToBoxAdapter(
                                  child: SizedBox(height: 120)),
                            ],
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.onOpen});
  final void Function(ServerMovie) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(movieSearchProvider);
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Search failed: $e')),
      data: (movies) => movies.isEmpty
          ? const _EmptyNote('No matches.')
          : CustomScrollView(
              slivers: [
                _PosterGrid(movies: movies, onOpen: onOpen),
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
    );
  }
}

/// The horizontal resume shelf — wider cards with a progress bar.
class _ContinueShelf extends StatelessWidget {
  const _ContinueShelf({required this.movies, required this.onOpen});
  final List<ServerMovie> movies;
  final void Function(ServerMovie) onOpen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 210,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        itemCount: movies.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final m = movies[i];
          return SizedBox(
            width: 116,
            child: _PosterCard(movie: m, onTap: () => onOpen(m), showProgress: true),
          );
        },
      ),
    );
  }
}

/// The main reflowing poster grid.
class _PosterGrid extends StatelessWidget {
  const _PosterGrid({required this.movies, required this.onOpen});
  final List<ServerMovie> movies;
  final void Function(ServerMovie) onOpen;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 150,
          mainAxisSpacing: 16,
          crossAxisSpacing: 14,
          // Poster (2:3) + a two-line caption below it.
          childAspectRatio: 0.52,
        ),
        itemCount: movies.length,
        itemBuilder: (context, i) => _PosterCard(
          movie: movies[i],
          onTap: () => onOpen(movies[i]),
        ),
      ),
    );
  }
}

/// A poster with a title/subtitle caption and an optional resume bar.
class _PosterCard extends StatelessWidget {
  const _PosterCard({
    required this.movie,
    required this.onTap,
    this.showProgress = false,
  });

  final ServerMovie movie;
  final VoidCallback onTap;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              Poster(
                  id: movie.id,
                  hasArt: movie.hasArt,
                  artVersion: movie.artVersion),
              if (showProgress && movie.progress > 0)
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: movie.progress,
                      minHeight: 3,
                      backgroundColor: Colors.black45,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            movie.isEpisode && movie.series.isNotEmpty
                ? movie.series
                : movie.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
          ),
          if (movie.subtitle.isNotEmpty)
            Text(
              movie.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
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
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
