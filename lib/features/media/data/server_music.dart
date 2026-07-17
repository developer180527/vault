import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/client/vault_client.dart';
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
