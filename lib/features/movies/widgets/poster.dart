import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/server_movies.dart';

/// A movie poster (2:3), cached via the content cache with a graceful
/// film-glyph placeholder. Used at every size from grid cell to detail hero.
class Poster extends ConsumerWidget {
  const Poster({
    super.key,
    required this.id,
    required this.hasArt,
    this.borderRadius = 10,
  });

  final String id;
  final bool hasArt;
  final double borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bytes =
        hasArt ? ref.watch(posterProvider(id)).asData?.value : null;
    return AspectRatio(
      aspectRatio: 2 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: bytes != null
            ? Image.memory(bytes,
                fit: BoxFit.cover, cacheWidth: 400, gaplessPlayback: true)
            : DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.surfaceContainerHigh,
                      scheme.surfaceContainerHighest,
                    ],
                  ),
                ),
                child: Icon(Icons.movie_outlined,
                    size: 32, color: scheme.onSurfaceVariant),
              ),
      ),
    );
  }
}
