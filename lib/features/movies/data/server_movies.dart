import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/cache/content_cache.dart';
import '../../../core/changes/server_changes.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/logging/vault_log.dart';
import '../../../core/models/server_movie.dart';

final _log = VaultLog.tag('movies');

/// Connected → the movie catalog is available.
final _connectedProvider = Provider<bool>(
  (ref) => ref.watch(sessionProvider).asData?.value != null,
);

/// Live search text for the catalog (empty = full catalog).
class MovieSearchQuery extends Notifier<String> {
  @override
  String build() => '';
  void set(String q) => state = q;
}

final movieSearchQueryProvider =
    NotifierProvider<MovieSearchQuery, String>(MovieSearchQuery.new);

/// The full catalog, snapshot-first so it paints instantly on a cold start.
class MovieCatalogNotifier extends AsyncNotifier<List<ServerMovie>> {
  @override
  Future<List<ServerMovie>> build() async {
    final scope = ref.watch(_scopeProvider);
    if (scope == null) return const [];
    // Server change feed: a "movies" bump (poster upload, edit, rescan…)
    // rebuilds the catalog → fresh art_version → new poster URLs.
    ref.watch(topicRevProvider('movies'));
    final cache = ref.watch(contentCacheProvider);
    final key = '$scope/movies.catalog';

    Future<List<ServerMovie>> refresh() async {
      final fresh = await ref.read(vaultClientProvider).movies.list();
      unawaited(cache.writeSnapshot(
          key, jsonEncode([for (final m in fresh) m.toJson()])));
      return fresh;
    }

    final snap = await cache.readSnapshot(key);
    if (snap == null) return refresh();
    // Refresh behind the snapshot; a network failure with a snapshot in hand
    // is demoted to a log line — stale beats broken.
    unawaited(() async {
      try {
        state = AsyncData(await refresh());
      } catch (e) {
        _log.debug('catalog refresh failed, serving snapshot',
            fields: {'err': '$e'});
      }
    }());
    try {
      return [
        for (final m in jsonDecode(snap) as List)
          ServerMovie.fromJson(m as Map<String, Object?>),
      ];
    } catch (_) {
      return refresh();
    }
  }
}

final movieCatalogProvider =
    AsyncNotifierProvider<MovieCatalogNotifier, List<ServerMovie>>(
        MovieCatalogNotifier.new);

/// Live FTS search results (never snapshot-cached — search must be truth).
final movieSearchProvider = FutureProvider<List<ServerMovie>>((ref) {
  if (!ref.watch(_connectedProvider)) return const [];
  ref.watch(topicRevProvider('movies')); // open search refreshes on changes
  final q = ref.watch(movieSearchQueryProvider).trim();
  if (q.isEmpty) return const [];
  return ref.watch(vaultClientProvider).movies.list(query: q);
});

/// The Continue Watching shelf. Invalidated after playback reports progress.
final continueWatchingProvider = FutureProvider<List<ServerMovie>>((ref) {
  if (!ref.watch(_connectedProvider)) return const [];
  return ref.watch(vaultClientProvider).movies.continueWatching();
});

/// One movie's detail (fresh resume position + full stream list).
final movieDetailProvider =
    FutureProvider.family<ServerMovie, String>((ref, id) {
  ref.watch(topicRevProvider('movies')); // metadata/poster edits reach detail
  return ref.watch(vaultClientProvider).movies.movie(id);
});

/// Poster bytes via the content cache (memory → disk → network, ETag
/// revalidated). autoDispose so scrolled-past posters don't pin memory.
/// Keyed by (id, artVersion): a poster upload bumps the version → new `?v=`
/// URL → new cache entry, so stale art can't outlive an admin change.
final posterProvider = FutureProvider.autoDispose
    .family<Uint8List?, ({String id, int v})>((ref, key) async {
  if (!ref.watch(_connectedProvider)) return null;
  final api = ref.watch(vaultClientProvider).movies;
  final cache = ref.watch(contentCacheProvider);
  return cache.image(
    api.artUri(key.id, version: key.v),
    headers: await api.authHeaders(),
  );
});

final _scopeProvider = Provider<String?>((ref) {
  final s = ref.watch(sessionProvider).asData?.value;
  return s == null ? null : '${s.serverHost}/${s.deviceId}';
});
