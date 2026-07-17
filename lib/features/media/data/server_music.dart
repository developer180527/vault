import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/models/playlist.dart';
import '../../../core/models/server_track.dart';
import '../../../core/playback/playable.dart';

/// Live search text for the server music list (empty = full library).
class MusicSearchQuery extends Notifier<String> {
  @override
  String build() => '';
  void set(String q) => state = q;
}

final musicSearchQueryProvider =
    NotifierProvider<MusicSearchQuery, String>(MusicSearchQuery.new);

/// Whether this device has a connected session (server music available).
final musicServerModeProvider = Provider<bool>(
    (ref) => ref.watch(sessionProvider).asData?.value != null);

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
    MusicApi music, List<ServerTrack> tracks) async {
  final headers = await music.authHeaders();
  return [
    for (final t in tracks)
      Playable(
        id: t.id,
        kind: PlayableKind.audio,
        uri: music.streamUri(t.id),
        title: t.title,
        subtitle: t.artist,
        album: t.album,
        headers: headers,
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

class MusicSourceNotifier extends Notifier<MusicSource> {
  @override
  MusicSource build() {
    // Login/logout resets to the catalog (and clears any stale playlist).
    ref.watch(musicServerModeProvider);
    return const CatalogSource();
  }

  void set(MusicSource s) => state = s;
}

final musicSourceProvider =
    NotifierProvider<MusicSourceNotifier, MusicSource>(MusicSourceNotifier.new);

/// The caller's playlists. Invalidated after any playlist mutation.
final playlistsProvider = FutureProvider<List<Playlist>>((ref) {
  if (!ref.watch(musicServerModeProvider)) return const [];
  return ref.watch(vaultClientProvider).music.playlists();
});

/// The track list for the ACTIVE source, honoring the live search query.
/// Playlist contents don't support server-side search — filtered client-side
/// (playlists are small by nature).
final sourceTracksProvider = FutureProvider<List<ServerTrack>>((ref) async {
  if (!ref.watch(musicServerModeProvider)) return const [];
  final music = ref.watch(vaultClientProvider).music;
  final q = ref.watch(musicSearchQueryProvider).trim();
  switch (ref.watch(musicSourceProvider)) {
    case CatalogSource():
      return music.catalog(query: q);
    case PersonalSource():
      return q.isEmpty ? music.tracks() : music.search(q);
    case PlaylistSource(playlist: final p):
      final tracks = await music.playlistTracks(p.id);
      if (q.isEmpty) return tracks;
      final needle = q.toLowerCase();
      return [
        for (final t in tracks)
          if (t.title.toLowerCase().contains(needle) ||
              t.artist.toLowerCase().contains(needle) ||
              t.album.toLowerCase().contains(needle))
            t,
      ];
  }
});

/// The listen-event `source` tag for what's on screen — raw fact recording
/// for the future recommender (`library` | `search` | `playlist:<id>`).
String listenSourceFor(MusicSource source, String query) {
  if (source is PlaylistSource) return 'playlist:${source.playlist.id}';
  return query.trim().isEmpty ? 'library' : 'search';
}

/// Maps CATALOG tracks to [Playable]s (shared stream/art endpoints).
Future<List<Playable>> catalogPlayables(
    MusicApi music, List<ServerTrack> tracks) async {
  final headers = await music.authHeaders();
  return [
    for (final t in tracks)
      Playable(
        id: t.id,
        kind: PlayableKind.audio,
        uri: music.catalogStreamUri(t.id),
        title: t.title,
        subtitle: t.artist,
        album: t.album,
        headers: headers,
      ),
  ];
}
