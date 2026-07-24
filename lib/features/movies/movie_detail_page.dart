import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/server_movie.dart';
import 'data/server_movies.dart';
import 'movie_player_page.dart';
import 'widgets/poster.dart';

/// Fullscreen detail for one title: poster, metadata, overview, a play/resume
/// button, and (for shows) the sibling episode list. Responsive — poster
/// beside the info on wide screens, stacked on phones.
class MovieDetailPage extends ConsumerWidget {
  const MovieDetailPage({super.key, required this.movieId});

  final String movieId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(movieDetailProvider(movieId));
    return Scaffold(
      appBar: AppBar(title: const Text('')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Unavailable: $e')),
        data: (movie) => LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth > 720;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 260,
                          child: Poster(
                              id: movie.id,
                              hasArt: movie.hasArt,
                              artVersion: movie.artVersion),
                        ),
                        const SizedBox(width: 32),
                        Expanded(child: _Info(movie: movie)),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: SizedBox(
                            width: 200,
                            child: Poster(
                              id: movie.id,
                              hasArt: movie.hasArt,
                              artVersion: movie.artVersion),
                          ),
                        ),
                        const SizedBox(height: 24),
                        _Info(movie: movie),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _Info extends ConsumerWidget {
  const _Info({required this.movie});
  final ServerMovie movie;

  static String _fmtDuration(int ms) {
    if (ms <= 0) return '';
    final m = ms ~/ 60000;
    final h = m ~/ 60;
    return h > 0 ? '${h}h ${m % 60}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final resumeMin = movie.resumeMs ~/ 60000;
    final meta = [
      if (movie.year > 0) '${movie.year}',
      if (movie.durationMs > 0) _fmtDuration(movie.durationMs),
      if (movie.height > 0) '${movie.height}p',
      if (movie.audio.length > 1) '${movie.audio.length} audio tracks',
      if (movie.subs.any((s) => s.text)) 'Subtitles',
    ].join('  ·  ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          movie.isEpisode && movie.series.isNotEmpty ? movie.series : movie.title,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (movie.isEpisode)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${movie.season > 0 ? 'S${movie.season}E${movie.episode} · ' : ''}${movie.title}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
            ),
          ),
        const SizedBox(height: 8),
        Text(meta, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 20),
        Row(
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: Text(movie.resumeMs > 0
                  ? 'Resume from ${resumeMin}m'
                  : 'Play'),
              onPressed: () => openMoviePlayer(context, movie),
            ),
            if (movie.resumeMs > 0) ...[
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => openMoviePlayer(
                    context,
                    // Play from the start: same movie, resume zeroed.
                    ServerMovie(
                      id: movie.id,
                      title: movie.title,
                      kind: movie.kind,
                      durationMs: movie.durationMs,
                      audio: movie.audio,
                      subs: movie.subs,
                      streamUrl: movie.streamUrl,
                    )),
                child: const Text('Start over'),
              ),
            ],
          ],
        ),
        if (movie.progress > 0) ...[
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: movie.progress,
              minHeight: 4,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
        if (movie.overview.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(movie.overview,
              style: const TextStyle(fontSize: 15, height: 1.5)),
        ],
        const SizedBox(height: 24),
        _TrackSummary(movie: movie),
      ],
    );
  }
}

/// A quiet summary of what's available — audio languages and subtitle
/// languages — so the user knows before playing.
class _TrackSummary extends StatelessWidget {
  const _TrackSummary({required this.movie});
  final ServerMovie movie;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audio = movie.audio.map((a) => a.label).join(', ');
    final subs = movie.subs.where((s) => s.text).map((s) => s.label).join(', ');
    if (audio.isEmpty && subs.isEmpty) return const SizedBox.shrink();
    TextStyle label = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (audio.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('Audio: $audio', style: label),
          ),
        if (subs.isNotEmpty) Text('Subtitles: $subs', style: label),
      ],
    );
  }
}
