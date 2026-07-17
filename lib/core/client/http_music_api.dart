import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../models/playlist.dart';
import '../models/server_track.dart';
import 'vault_client.dart';

/// vaultd's music API (docs/MUSIC.md): the index lives server-side; this
/// client lists/searches it and hands stream/artwork URLs (+ bearer) to the
/// playback engine and image widgets.
class HttpMusicApi implements MusicApi {
  HttpMusicApi(this._ref);

  final Ref _ref;

  Session get _session {
    final s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    return s;
  }

  Future<String> _token() async {
    var s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    if (s.accessExpires.isBefore(DateTime.now())) {
      s = await _ref.read(sessionProvider.notifier).refresh();
      if (s == null) throw Exception('session revoked');
    }
    return s.accessToken;
  }

  @override
  Future<Map<String, String>> authHeaders() async =>
      {'Authorization': 'Bearer ${await _token()}'};

  @override
  Uri streamUri(String id) => _session.api('/v1/music/tracks/$id/stream');

  @override
  Uri artUri(String id) => _session.api('/v1/music/tracks/$id/art');

  @override
  Future<List<ServerTrack>> tracks() => _fetch(_session.api('/v1/music/tracks'));

  @override
  Future<List<ServerTrack>> search(String query) => _fetch(_session
      .api('/v1/music/search')
      .replace(queryParameters: {'q': query}));

  // --- shared catalog (admin-curated; everyone streams) ---

  @override
  Uri catalogStreamUri(String id) =>
      _session.api('/v1/music/catalog/$id/stream');

  @override
  Uri catalogArtUri(String id) => _session.api('/v1/music/catalog/$id/art');

  @override
  Future<List<ServerTrack>> catalog({String query = ''}) {
    var uri = _session.api('/v1/music/catalog');
    if (query.isNotEmpty) uri = uri.replace(queryParameters: {'q': query});
    return _fetch(uri);
  }

  @override
  Future<List<Playlist>> playlists() async {
    final body = await _json('GET', '/v1/music/playlists');
    final raw = (body['playlists'] as List?) ?? const [];
    return [
      for (final p in raw) Playlist.fromJson(p as Map<String, Object?>),
    ];
  }

  @override
  Future<Playlist> createPlaylist(String name) async =>
      Playlist.fromJson(await _json('POST', '/v1/music/playlists',
          body: {'name': name}, expect: 201));

  @override
  Future<void> deletePlaylist(String id) =>
      _json('DELETE', '/v1/music/playlists/$id');

  @override
  Future<List<ServerTrack>> playlistTracks(String id) =>
      _fetch(_session.api('/v1/music/playlists/$id/tracks'));

  @override
  Future<void> addToPlaylist(String playlistId, String trackId) =>
      _json('POST', '/v1/music/playlists/$playlistId/tracks',
          body: {'track_id': trackId});

  @override
  Future<void> removeFromPlaylist(String playlistId, String trackId) =>
      _json('DELETE', '/v1/music/playlists/$playlistId/tracks/$trackId');

  @override
  Future<void> reportListen(String trackId,
      {String source = '', int msPlayed = 0}) async {
    // Fire-and-forget by contract: swallow failures so playback never stalls
    // on telemetry (the listen log is best-effort food for future ML).
    try {
      await _json('POST', '/v1/music/listens',
          body: {'track_id': trackId, 'source': source, 'ms_played': msPlayed},
          expect: 201);
    } catch (_) {}
  }

  Future<List<ServerTrack>> _fetch(Uri uri) async {
    final res = await http.get(uri, headers: await authHeaders());
    if (res.statusCode != 200) {
      throw Exception('music request failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, Object?>;
    final raw = (body['tracks'] as List?) ?? const [];
    return [
      for (final t in raw) ServerTrack.fromJson(t as Map<String, Object?>),
    ];
  }

  /// One JSON round-trip with auth; throws on unexpected status.
  Future<Map<String, Object?>> _json(String method, String path,
      {Map<String, Object?>? body, int expect = 200}) async {
    final req = http.Request(method, _session.api(path));
    req.headers.addAll(await authHeaders());
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != expect) {
      throw Exception('music request failed: HTTP ${res.statusCode}');
    }
    return res.body.isEmpty
        ? const {}
        : jsonDecode(res.body) as Map<String, Object?>;
  }
}
