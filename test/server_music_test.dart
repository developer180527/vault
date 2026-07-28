import 'package:flutter_test/flutter_test.dart';

import 'package:vault/core/client/vault_client.dart';
import 'package:vault/core/models/playlist.dart';
import 'package:vault/core/models/server_track.dart';
import 'package:vault/core/playback/playable.dart';
import 'package:vault/features/media/data/server_music.dart';

class _FakeMusicApi implements MusicApi {
  final listens = <(String, String)>[];

  @override
  Future<Map<String, String>> authHeaders() async =>
      {'Authorization': 'Bearer tok-1'};

  @override
  Uri streamUri(String id) => Uri.parse('https://vault/v1/music/tracks/$id/stream');

  @override
  Uri artUri(String id) => Uri.parse('https://vault/v1/music/tracks/$id/art');

  @override
  Uri resolveStreamUrl(String pathWithQuery) =>
      Uri.parse('https://vault$pathWithQuery');

  @override
  Future<Uri?> freshStreamUrl(String id, {bool catalog = false}) async =>
      Uri.parse('https://vault/v1/music/${catalog ? 'catalog' : 'tracks'}/$id/stream?sig=fresh');

  @override
  Future<List<ServerTrack>> tracks() async => const [];

  @override
  Future<List<ServerTrack>> search(String query) async => const [];

  @override
  Uri catalogStreamUri(String id) =>
      Uri.parse('https://vault/v1/music/catalog/$id/stream');

  @override
  Uri catalogArtUri(String id, {int version = 0}) =>
      Uri.parse('https://vault/v1/music/catalog/$id/art');

  @override
  Future<List<ServerTrack>> catalog({String query = ''}) async => const [];

  @override
  Future<List<Playlist>> playlists() async => const [];

  @override
  Future<Playlist> createPlaylist(String name) async =>
      Playlist(id: 'p1', name: name);

  @override
  Future<void> deletePlaylist(String id) async {}

  @override
  Future<List<ServerTrack>> playlistTracks(String id) async => const [];

  @override
  Future<void> addToPlaylist(String playlistId, String trackId) async {}

  @override
  Future<void> removeFromPlaylist(String playlistId, String trackId) async {}

  @override
  Future<void> reportListen(String trackId,
      {String source = '', int msPlayed = 0}) async {
    listens.add((trackId, source));
  }

  @override
  Future<List<ServerTrack>> mostPlayed() async => const [];

  @override
  Future<List<ServerTrack>> favorites() async => const [];

  @override
  Future<void> addFavorite(String trackId) async {}

  @override
  Future<void> removeFavorite(String trackId) async {}
}

void main() {
  test('ServerTrack.fromJson tolerates missing optional fields', () {
    final t = ServerTrack.fromJson(const {'id': 'x', 'title': 'Song'});
    expect(t.id, 'x');
    expect(t.artist, '');
    expect(t.hasArt, isFalse);

    final full = ServerTrack.fromJson(const {
      'id': 'y',
      'title': 'One More Time',
      'artist': 'Daft Punk',
      'album': 'Discovery',
      'track_no': 2,
      'year': 2001,
      'has_art': true,
    });
    expect(full.artist, 'Daft Punk');
    expect(full.trackNo, 2);
    expect(full.hasArt, isTrue);
  });

  test('serverPlayables maps tracks to authed network Playables', () async {
    final playables = await serverPlayables(_FakeMusicApi(), const [
      ServerTrack(id: 't1', title: 'A', artist: 'X', album: 'Al'),
      ServerTrack(id: 't2', title: 'B'),
    ]);

    expect(playables, hasLength(2));
    final p = playables.first;
    expect(p.kind, PlayableKind.audio);
    expect(p.id, 't1');
    expect(p.uri.toString(), 'https://vault/v1/music/tracks/t1/stream');
    expect(p.headers['Authorization'], 'Bearer tok-1');
    expect(p.subtitle, 'X');
    expect(p.album, 'Al');
    expect(p.isNetwork, isTrue); // → engine streams, not file-opens
  });

  test('catalogPlayables streams from the shared catalog endpoints', () async {
    final playables = await catalogPlayables(_FakeMusicApi(), const [
      ServerTrack(id: 'c1', title: 'Shared', artist: 'Q'),
    ]);
    expect(playables.single.uri.toString(),
        'https://vault/v1/music/catalog/c1/stream');
    expect(playables.single.headers['Authorization'], 'Bearer tok-1');
  });

  test('playables prefer the signed stream_url when the server sends one',
      () async {
    const signed = '/v1/music/catalog/c2/stream?exp=99&sig=abc';
    final playables = await catalogPlayables(_FakeMusicApi(), const [
      ServerTrack(id: 'c2', title: 'Signed', streamUrl: signed),
    ]);
    expect(playables.single.uri.toString(), 'https://vault$signed');

    final personal = await serverPlayables(_FakeMusicApi(), const [
      ServerTrack(
          id: 't9',
          title: 'Mine',
          streamUrl: '/v1/music/tracks/t9/stream?u=venu&exp=99&sig=def'),
    ]);
    expect(personal.single.uri.queryParameters['sig'], 'def');
  });

  test('ServerTrack stream_url round-trips through json (snapshot cache)', () {
    const t = ServerTrack(
        id: 'x', title: 'T', streamUrl: '/v1/music/catalog/x/stream?sig=s');
    final back = ServerTrack.fromJson(t.toJson());
    expect(back.streamUrl, t.streamUrl);
    // Absent on old servers → null, not empty string.
    expect(ServerTrack.fromJson(const {'id': 'y', 'title': 'Y'}).streamUrl,
        isNull);
  });

  test('listenSourceFor tags events for the future recommender', () {
    expect(listenSourceFor(const CatalogSource(), ''), 'library');
    expect(listenSourceFor(const CatalogSource(), 'quee'), 'search');
    expect(
        listenSourceFor(
            const PlaylistSource(Playlist(id: 'p9', name: 'Focus')), 'x'),
        'playlist:p9');
  });

  test('Playlist.fromJson tolerates missing count', () {
    final p = Playlist.fromJson(const {'id': 'p1', 'name': 'Focus'});
    expect(p.trackCount, 0);
    final full = Playlist.fromJson(
        const {'id': 'p2', 'name': 'Gym', 'track_count': 7});
    expect(full.trackCount, 7);
  });


  // --- multi-value tags (artist + genre are authored as chips, stored joined) ---

  test('splitTagValues splits on commas only, trims, and de-dupes', () {
    expect(splitTagValues('Asha Bhosle, Mohammed Rafi'),
        ['Asha Bhosle', 'Mohammed Rafi']);
    // "&" must NOT split — it's part of duo names.
    expect(splitTagValues('Simon & Garfunkel'), ['Simon & Garfunkel']);
    // Whitespace and empty segments are cleaned up.
    expect(splitTagValues('  Pop ,, Romantic  ,'), ['Pop', 'Romantic']);
    // Case-insensitive de-dupe, first spelling wins — a track tagged
    // "Pop, pop" must not file itself twice under one heading.
    expect(splitTagValues('Pop, pop, POP'), ['Pop']);
    expect(splitTagValues(''), isEmpty);
  });

  test('a multi-genre track files under EACH genre, not one joined heading',
      () {
    const t = ServerTrack(
      id: '1',
      title: 'Yeh Sham Mastani',
      artist: 'Kishore Kumar',
      album: 'Kati Patang',
      genre: 'Indian Pop, Romantic, Pop',
    );
    final groups = groupTracks([t], (x) => splitGenres(x.genre),
        unknownLabel: 'Unsorted');
    expect(groups.map((g) => g.label), ['Indian Pop', 'Pop', 'Romantic']);
    for (final g in groups) {
      expect(g.tracks.single.id, '1');
    }
  });

  test('a duet files under both performers', () {
    const t = ServerTrack(
      id: '2',
      title: 'Intaha Ho Gai',
      artist: 'Kishore Kumar, Asha Bhosle',
    );
    final groups = groupTracks([t], (x) => splitArtists(x.artist),
        unknownLabel: 'Unknown artist');
    expect(groups.map((g) => g.label), ['Asha Bhosle', 'Kishore Kumar']);
  });

  test('untagged tracks stay reachable in the unknown bucket', () {
    const t = ServerTrack(id: '3', title: 'Untitled', genre: '  ');
    final groups =
        groupTracks([t], (x) => splitGenres(x.genre), unknownLabel: 'Unsorted');
    expect(groups.single.label, 'Unsorted');
    expect(groups.single.tracks.single.id, '3');
  });
}
