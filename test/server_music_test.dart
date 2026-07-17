import 'package:flutter_test/flutter_test.dart';

import 'package:vault/core/client/vault_client.dart';
import 'package:vault/core/models/server_track.dart';
import 'package:vault/core/playback/playable.dart';
import 'package:vault/features/media/data/server_music.dart';

class _FakeMusicApi implements MusicApi {
  @override
  Future<Map<String, String>> authHeaders() async =>
      {'Authorization': 'Bearer tok-1'};

  @override
  Uri streamUri(String id) => Uri.parse('https://vault/v1/music/tracks/$id/stream');

  @override
  Uri artUri(String id) => Uri.parse('https://vault/v1/music/tracks/$id/art');

  @override
  Future<List<ServerTrack>> tracks() async => const [];

  @override
  Future<List<ServerTrack>> search(String query) async => const [];
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
}
