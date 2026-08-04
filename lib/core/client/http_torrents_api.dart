import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../jobs/job.dart';
import 'vault_client.dart';

/// Remote torrent control against `/v1/torrents/*`.
///
/// Nothing here scopes anything to a user — that is deliberate and must stay
/// that way. The server resolves every hash to its owning category before it
/// acts, so a client cannot widen its own reach by sending a different hash.
class HttpTorrentsApi implements TorrentsApi {
  HttpTorrentsApi(this._ref);

  final Ref _ref;

  Session get _session {
    final s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    return s;
  }

  Future<Map<String, String>> _auth() async {
    var s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    if (s.needsRenewal) {
      s = await _ref.read(sessionProvider.notifier).refresh();
      if (s == null) throw Exception('session revoked');
    }
    return {'Authorization': 'Bearer ${s.accessToken}'};
  }

  @override
  Future<List<TorrentEntry>> list() async {
    final res =
        await http.get(_session.api('/v1/torrents'), headers: await _auth());
    if (res.statusCode == 503) {
      throw const TorrentsUnavailable();
    }
    if (res.statusCode != 200) {
      throw Exception('torrent list failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return [
      for (final t in (body['torrents'] as List?) ?? const [])
        TorrentEntry.fromJson(t as Map<String, Object?>),
    ];
  }

  @override
  Future<TransferStats> transfer() async {
    final res = await http.get(_session.api('/v1/torrents/transfer'),
        headers: await _auth());
    if (res.statusCode == 503) throw const TorrentsUnavailable();
    if (res.statusCode != 200) {
      throw Exception('transfer info failed: HTTP ${res.statusCode}');
    }
    return TransferStats.fromJson(
        jsonDecode(res.body) as Map<String, Object?>);
  }

  @override
  Future<void> addFile(String filename, Uint8List bytes,
      {JobDest dest = JobDest.myFiles}) async {
    final uri = _session.api('/v1/torrents/file').replace(queryParameters: {
      'name': filename,
      if (dest != JobDest.myFiles) 'dest': dest.wire,
    });
    final req = http.Request('POST', uri)
      ..headers.addAll(await _auth())
      ..headers['Content-Type'] = 'application/x-bittorrent'
      ..bodyBytes = bytes;
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode == 415) {
      throw Exception("That doesn't look like a .torrent file.");
    }
    if (res.statusCode != 200) {
      throw Exception('add failed: HTTP ${res.statusCode} ${res.body}');
    }
  }

  @override
  Future<void> pause(String hash) => _post('/v1/torrents/$hash/pause');

  @override
  Future<void> resume(String hash) => _post('/v1/torrents/$hash/resume');

  @override
  Future<void> recheck(String hash) => _post('/v1/torrents/$hash/recheck');

  @override
  Future<void> remove(String hash, {required bool withData}) async {
    final uri = _session
        .api('/v1/torrents/$hash')
        .replace(queryParameters: withData ? {'files': '1'} : null);
    final res = await http.delete(uri, headers: await _auth());
    if (res.statusCode != 200) {
      throw Exception('remove failed: HTTP ${res.statusCode}');
    }
  }

  @override
  Future<void> setLimits({int? dlLimit, int? upLimit}) async {
    final res = await http.put(
      _session.api('/v1/torrents/limits'),
      headers: {...await _auth(), 'Content-Type': 'application/json'},
      // Only send what changed: the server keeps the other limit as-is, so a
      // one-sided edit can't silently clear the other.
      body: jsonEncode({
        'dl_limit': ?dlLimit,
        'up_limit': ?upLimit,
      }),
    );
    if (res.statusCode == 403) {
      throw Exception('Only an admin can change the household speed limits.');
    }
    if (res.statusCode != 200) {
      throw Exception('set limits failed: HTTP ${res.statusCode}');
    }
  }

  Future<void> _post(String path) async {
    final res =
        await http.post(_session.api(path), headers: await _auth());
    if (res.statusCode == 404) {
      throw Exception('That torrent is no longer there.');
    }
    if (res.statusCode != 200) {
      throw Exception('$path failed: HTTP ${res.statusCode}');
    }
  }
}

/// The server has no qBittorrent configured. Distinct from a transport failure
/// so the UI can say "not set up" instead of "something broke".
class TorrentsUnavailable implements Exception {
  const TorrentsUnavailable();
  @override
  String toString() => 'Torrents are not configured on this server.';
}
