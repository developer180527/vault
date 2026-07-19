import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../models/server_movie.dart';
import 'vault_client.dart';

/// vaultd's movie catalog API (/v1/movies) — list/search, signed streaming,
/// multi-track audio + WebVTT subtitles, and server-side resume.
class HttpMoviesApi implements MoviesApi {
  HttpMoviesApi(this._ref);

  final Ref _ref;

  Session get _session {
    final s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    return s;
  }

  Future<Map<String, String>> _auth() async {
    var s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    if (s.accessExpires.isBefore(DateTime.now())) {
      s = await _ref.read(sessionProvider.notifier).refresh();
      if (s == null) throw Exception('session revoked');
    }
    return {'Authorization': 'Bearer ${s.accessToken}'};
  }

  @override
  Future<Map<String, String>> authHeaders() => _auth();

  @override
  Future<List<ServerMovie>> list({String query = ''}) {
    var uri = _session.api('/v1/movies');
    if (query.isNotEmpty) uri = uri.replace(queryParameters: {'q': query});
    return _fetchList(uri);
  }

  @override
  Future<List<ServerMovie>> continueWatching() =>
      _fetchList(_session.api('/v1/movies/continue'));

  @override
  Future<ServerMovie> movie(String id) async {
    final res = await http.get(_session.api('/v1/movies/$id'),
        headers: await _auth());
    if (res.statusCode != 200) {
      throw Exception('movie fetch failed: HTTP ${res.statusCode}');
    }
    return ServerMovie.fromJson(jsonDecode(res.body) as Map<String, Object?>);
  }

  @override
  Future<void> reportWatch(String id,
      {required int positionMs, required int durationMs}) async {
    try {
      await http.post(
        _session.api('/v1/movies/$id/watches'),
        headers: {...await _auth(), 'Content-Type': 'application/json'},
        body: jsonEncode({'position_ms': positionMs, 'duration_ms': durationMs}),
      );
    } catch (_) {
      // Fire-and-forget: resume tracking must never break playback.
    }
  }

  @override
  Uri streamUri(String id, {int audio = 0, int startSec = 0}) {
    final q = <String, String>{};
    if (audio > 0) q['audio'] = '$audio';
    if (startSec > 0) q['start'] = '$startSec';
    final base = _session.api('/v1/movies/$id/stream');
    return q.isEmpty ? base : base.replace(queryParameters: q);
  }

  @override
  Uri resolveStreamUrl(String pathWithQuery) {
    final parts = pathWithQuery.split('?');
    final base = _session.api(parts.first);
    return parts.length > 1 ? base.replace(query: parts[1]) : base;
  }

  @override
  Uri artUri(String id) => _session.api('/v1/movies/$id/art');

  @override
  Uri subUri(String id, String track) =>
      _session.api('/v1/movies/$id/subs/$track.vtt');

  @override
  Future<String> subtitleVtt(String id, String track) async {
    final res = await http.get(subUri(id, track), headers: await _auth());
    if (res.statusCode != 200) {
      throw Exception('subtitle fetch failed: HTTP ${res.statusCode}');
    }
    return res.body;
  }

  Future<List<ServerMovie>> _fetchList(Uri uri) async {
    final res = await http.get(uri, headers: await _auth());
    if (res.statusCode != 200) {
      throw Exception('movies request failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return [
      for (final m in (body['movies'] as List?) ?? const [])
        ServerMovie.fromJson(m as Map<String, Object?>),
    ];
  }
}
