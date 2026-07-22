import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/session.dart';
import '../../../core/cache/content_cache.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/logging/vault_log.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/server_track.dart';
import '../../../core/playback/playable.dart';

final _log = VaultLog.tag('serverMusic');

/// Live search text for the server music list (empty = full library).
class MusicSearchQuery extends Notifier<String> {
  @override
  String build() => '';
  void set(String q) => state = q;
}

final musicSearchQueryProvider = NotifierProvider<MusicSearchQuery, String>(
  MusicSearchQuery.new,
);

/// Whether this device has a connected session (server music available).
final musicServerModeProvider = Provider<bool>(
  (ref) => ref.watch(sessionProvider).asData?.value != null,
);

/// The server library (or search results). Re-fetches when the session or
/// query changes; the server rescans incrementally per listing, so this is
/// always disk-truth (docs/MUSIC.md).
final serverTracksProvider = FutureProvider<List<ServerTrack>>((ref) async {
  if (!ref.watch(musicServerModeProvider)) return const [];
  final music = ref.watch(vaultClientProvider).music;
  final q = ref.watch(musicSearchQueryProvider).trim();
  return q.isEmpty ? music.tracks() : music.search(q);
});

/// Bearer headers for artwork/stream fetches from image widgets (fetched once
/// per session state; the playback queue re-fetches fresh ones itself).
final musicAuthHeadersProvider = FutureProvider<Map<String, String>>((ref) {
  if (!ref.watch(musicServerModeProvider)) return Future.value(const {});
  return ref.watch(vaultClientProvider).music.authHeaders();
});

/// Maps server tracks to [Playable]s for the central player. Fetches fresh
/// auth headers once for the whole queue.
Future<List<Playable>> serverPlayables(
  MusicApi music,
  List<ServerTrack> tracks,
) async {
  final headers = await music.authHeaders();
  return [
    for (final t in tracks)
      Playable(
        id: t.id,
        kind: PlayableKind.audio,
        // Signed URL when the server provides one: playback then outlives
        // the 15-minute bearer (loop restarts / queue wraps kept 401ing on
        // the stale header). Bearer fallback for old servers.
        uri: t.streamUrl != null
            ? music.resolveStreamUrl(t.streamUrl!)
            : music.streamUri(t.id),
        title: t.title,
        subtitle: t.artist,
        album: t.album,
        artworkUri: t.hasArt ? music.artUri(t.id) : null,
        // A signed URL carries its own auth: send NO stream headers so the
        // native player streams directly (Range/206) instead of through
        // just_audio's header-injection proxy. Art keeps its own bearer.
        // Without a signed URL we still need the bearer on the stream itself.
        headers: t.streamUrl != null ? const {} : headers,
        artHeaders: headers,
        refreshUri: () => music.freshStreamUrl(t.id),
      ),
  ];
}

// --- shared catalog (admin-curated; docs/MUSIC.md) ---

/// What the connected Music tab is showing: the shared catalog (default),
/// the caller's personal music zone, or one of their playlists.
sealed class MusicSource {
  const MusicSource();
}

class CatalogSource extends MusicSource {
  const CatalogSource();
}

class PersonalSource extends MusicSource {
  const PersonalSource();
}

class PlaylistSource extends MusicSource {
  const PlaylistSource(this.playlist);
  final Playlist playlist;
}

// ---- snapshot-first listings (ContentCache: core stale-while-revalidate) --
//
// Cold start paints the LAST-KNOWN listing from disk in one frame, then the
// network copy refreshes behind it. The snapshot key is scoped to
// server+device so switching servers/accounts never shows someone else's
// library.

/// Scope prefix for snapshots (`serverHost/deviceId`). When CONNECTED it's the
/// live session's scope, and we persist it; when DISCONNECTED we fall back to
/// the LAST persisted scope so the cached library is still readable offline.
class LastMusicScope extends AsyncNotifier<String?> {
  static const _key = 'last_music_scope_v1';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final s = ref.watch(sessionProvider).asData?.value;
    if (s != null) {
      final scope = '${s.serverHost}/${s.deviceId}';
      await prefs.setString(_key, scope);
      return scope;
    }
    return prefs.getString(_key);
  }
}

final lastMusicScopeProvider =
    AsyncNotifierProvider<LastMusicScope, String?>(LastMusicScope.new);

/// Shared snapshot-first fetch: cached copy now, fresh copy when it lands
/// (via [update]). Network errors with a snapshot in hand are demoted to a
/// log line — stale beats broken.
Future<List<T>> _snapshotFirst<T>({
  required Ref ref,
  required String name,
  required Future<List<T>> Function() fetch,
  required Map<String, Object?> Function(T) encode,
  required T Function(Map<String, Object?>) decode,
  required void Function(List<T>) update,
}) async {
  final scope = await ref.watch(lastMusicScopeProvider.future);
  if (scope == null) return const [];
  final connected = ref.watch(musicServerModeProvider);
  final cache = ref.watch(contentCacheProvider);
  final key = '$scope/$name';

  List<T> decodeSnap(String snap) => [
        for (final t in jsonDecode(snap) as List)
          decode(t as Map<String, Object?>),
      ];

  // OFFLINE: serve the last cached listing read-only — no fetch. This is what
  // lets the music library still open (browse) with no server connection.
  if (!connected) {
    final snap = await cache.readSnapshot(key);
    if (snap == null) return const [];
    try {
      return decodeSnap(snap);
    } catch (_) {
      return const [];
    }
  }

  Future<List<T>> refresh() async {
    final fresh = await fetch();
    unawaited(
      cache.writeSnapshot(key, jsonEncode([for (final t in fresh) encode(t)])),
    );
    return fresh;
  }

  final snap = await cache.readSnapshot(key);
  if (snap == null) return refresh();

  // Have a snapshot: return it NOW; the fresh copy updates state behind it.
  unawaited(
    refresh().then(update).catchError((Object e) {
      _log.debug(
        'refresh failed, serving snapshot',
        fields: {'name': name, 'err': '$e'},
      );
    }),
  );
  try {
    return decodeSnap(snap);
  } catch (_) {
    return refresh(); // corrupt snapshot → straight to the network
  }
}

/// The caller's playlists. Invalidated after any playlist mutation.
class PlaylistsNotifier extends AsyncNotifier<List<Playlist>> {
  @override
  Future<List<Playlist>> build() => _snapshotFirst(
    ref: ref,
    name: 'music.playlists',
    fetch: () => ref.read(vaultClientProvider).music.playlists(),
    encode: (p) => p.toJson(),
    decode: Playlist.fromJson,
    update: (fresh) => state = AsyncData(fresh),
  );
}

final playlistsProvider =
    AsyncNotifierProvider<PlaylistsNotifier, List<Playlist>>(
      PlaylistsNotifier.new,
    );

// Per-SECTION track providers (the Music tab is Home / Search / Library, each
// its own surface — no shared "active source" state to entangle them).

/// Home: the full shared catalog, browse order (artist → album → track).
class CatalogTracksNotifier extends AsyncNotifier<List<ServerTrack>> {
  @override
  Future<List<ServerTrack>> build() => _snapshotFirst(
    ref: ref,
    name: 'music.catalog',
    fetch: () => ref.read(vaultClientProvider).music.catalog(),
    encode: (t) => t.toJson(),
    decode: ServerTrack.fromJson,
    update: (fresh) => state = AsyncData(fresh),
  );
}

final catalogTracksProvider =
    AsyncNotifierProvider<CatalogTracksNotifier, List<ServerTrack>>(
      CatalogTracksNotifier.new,
    );

/// Search: catalog FTS results for the live query (empty query = no results —
/// the search page idles until the user types). Live queries are never
/// snapshot-cached: search must be truth, and it's already index-fast.
final catalogSearchProvider = FutureProvider<List<ServerTrack>>((ref) {
  if (!ref.watch(musicServerModeProvider)) return const [];
  final q = ref.watch(musicSearchQueryProvider).trim();
  if (q.isEmpty) return const [];
  return ref.watch(vaultClientProvider).music.catalog(query: q);
});

/// Library: the caller's PERSONAL music zone (`users/<name>/music`).
class PersonalTracksNotifier extends AsyncNotifier<List<ServerTrack>> {
  @override
  Future<List<ServerTrack>> build() => _snapshotFirst(
    ref: ref,
    name: 'music.personal',
    fetch: () => ref.read(vaultClientProvider).music.tracks(),
    encode: (t) => t.toJson(),
    decode: ServerTrack.fromJson,
    update: (fresh) => state = AsyncData(fresh),
  );
}

final personalTracksProvider =
    AsyncNotifierProvider<PersonalTracksNotifier, List<ServerTrack>>(
      PersonalTracksNotifier.new,
    );

/// Album art bytes via the content cache: memory → disk (instant) → network,
/// with background ETag revalidation. Keyed by URL string; bearer headers are
/// fetched fresh inside so an expired token never poisons the cache.
///
/// autoDispose: WITHOUT it every scrolled-past track pinned its full-size art
/// bytes in provider state forever (hundreds of MB on a large catalog). The
/// ContentCache's LRU + disk make re-entry instant when a row scrolls back.
final artBytesProvider = FutureProvider.autoDispose.family<Uint8List?, String>((
  ref,
  url,
) async {
  if (!ref.watch(musicServerModeProvider)) return null;
  final cache = ref.watch(contentCacheProvider);
  final headers = await ref.watch(vaultClientProvider).music.authHeaders();
  return cache.image(Uri.parse(url), headers: headers);
});

/// Library: one playlist's tracks, position-ordered.
final playlistTracksProvider = FutureProvider.family<List<ServerTrack>, String>(
  (ref, playlistId) {
    if (!ref.watch(musicServerModeProvider)) return const [];
    return ref.watch(vaultClientProvider).music.playlistTracks(playlistId);
  },
);

/// Library: the caller's liked songs. Snapshot-first (paints instantly on cold
/// start), invalidated after any like/unlike so the section stays truthful.
class FavoritesNotifier extends AsyncNotifier<List<ServerTrack>> {
  @override
  Future<List<ServerTrack>> build() => _snapshotFirst(
    ref: ref,
    name: 'music.favorites',
    fetch: () => ref.read(vaultClientProvider).music.favorites(),
    encode: (t) => t.toJson(),
    decode: ServerTrack.fromJson,
    update: (fresh) => state = AsyncData(fresh),
  );
}

final favoritesProvider =
    AsyncNotifierProvider<FavoritesNotifier, List<ServerTrack>>(
      FavoritesNotifier.new,
    );

/// The set of liked track ids — the single source of truth for heart states
/// everywhere (rows, player), derived from [favoritesProvider] so one
/// invalidation flips every heart at once.
final favoriteIdsProvider = Provider<Set<String>>((ref) {
  final favs = ref.watch(favoritesProvider).asData?.value ?? const [];
  return {for (final t in favs) t.id};
});

/// Home "You" shelf: the caller's most-played catalog tracks. Snapshot-first
/// so the shelf survives a cold, offline start.
class MostPlayedNotifier extends AsyncNotifier<List<ServerTrack>> {
  @override
  Future<List<ServerTrack>> build() => _snapshotFirst(
    ref: ref,
    name: 'music.most_played',
    fetch: () => ref.read(vaultClientProvider).music.mostPlayed(),
    encode: (t) => t.toJson(),
    decode: ServerTrack.fromJson,
    update: (fresh) => state = AsyncData(fresh),
  );
}

final mostPlayedProvider =
    AsyncNotifierProvider<MostPlayedNotifier, List<ServerTrack>>(
      MostPlayedNotifier.new,
    );

/// One catalog dimension for Home browsing: a labeled bucket of tracks
/// (an artist, or a genre) plus the tracks under it.
class TrackGroup {
  const TrackGroup(this.label, this.tracks);
  final String label;
  final List<ServerTrack> tracks;
}

/// Splits a credit string into individual artists: "Asha Bhosle, Mohammed
/// Rafi" is TWO artists, not one combined act. Comma is the only separator —
/// splitting on "&" would wrongly cut duo names like "Simon & Garfunkel".
List<String> splitArtists(String credit) => [
  for (final part in credit.split(','))
    if (part.trim().isNotEmpty) part.trim(),
];

/// Groups catalog tracks into alphabetically-ordered [TrackGroup]s. [keysOf]
/// may return SEVERAL keys per track — a duet files under each of its
/// artists. No key at all lands in a single trailing bucket so untagged
/// tracks stay reachable rather than silently dropped.
List<TrackGroup> groupTracks(
  List<ServerTrack> tracks,
  Iterable<String> Function(ServerTrack) keysOf, {
  required String unknownLabel,
}) {
  final buckets = <String, List<ServerTrack>>{};
  for (final t in tracks) {
    final keys = [
      for (final k in keysOf(t))
        if (k.trim().isNotEmpty) k.trim(),
    ];
    if (keys.isEmpty) {
      buckets.putIfAbsent('', () => []).add(t);
      continue;
    }
    for (final k in keys) {
      buckets.putIfAbsent(k, () => []).add(t);
    }
  }
  final keys = buckets.keys.toList()
    ..sort((a, b) {
      if (a.isEmpty) return 1; // unknown sinks to the bottom
      if (b.isEmpty) return -1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  return [
    for (final k in keys) TrackGroup(k.isEmpty ? unknownLabel : k, buckets[k]!),
  ];
}

/// The listen-event `source` tag for what's on screen — raw fact recording
/// for the future recommender (`library` | `search` | `playlist:<id>`).
String listenSourceFor(MusicSource source, String query) {
  if (source is PlaylistSource) return 'playlist:${source.playlist.id}';
  return query.trim().isEmpty ? 'library' : 'search';
}

/// Maps CATALOG tracks to [Playable]s (shared stream/art endpoints).
Future<List<Playable>> catalogPlayables(
  MusicApi music,
  List<ServerTrack> tracks,
) async {
  final headers = await music.authHeaders();
  return [
    for (final t in tracks)
      Playable(
        id: t.id,
        kind: PlayableKind.audio,
        // Signed URL preferred — see serverPlayables.
        uri: t.streamUrl != null
            ? music.resolveStreamUrl(t.streamUrl!)
            : music.catalogStreamUri(t.id),
        title: t.title,
        subtitle: t.artist,
        album: t.album,
        artworkUri: t.hasArt ? music.catalogArtUri(t.id) : null,
        // Signed → bare stream (native, no proxy); art keeps the bearer.
        headers: t.streamUrl != null ? const {} : headers,
        artHeaders: headers,
        refreshUri: () => music.freshStreamUrl(t.id, catalog: true),
      ),
  ];
}
