import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
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
}
