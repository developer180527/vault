import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import 'vault_client.dart';

/// vaultd's sync-folder API (/v1/synced-folders): provenance lifecycle. File
/// bytes go through the Files upload endpoint, reused here.
class HttpSyncApi implements SyncApi {
  HttpSyncApi(this._ref);

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
  Future<List<SyncedFolderInfo>> list() async {
    final res = await http.get(_session.api('/v1/synced-folders'),
        headers: await _auth());
    if (res.statusCode != 200) {
      throw Exception('synced folders list failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return [
      for (final f in (body['folders'] as List?) ?? const [])
        SyncedFolderInfo.fromJson(f as Map<String, Object?>),
    ];
  }

  @override
  Future<(SyncedFolderInfo, String)> create({
    required String name,
    required String originDevice,
    required String originPlatform,
  }) async {
    final res = await http.post(
      _session.api('/v1/synced-folders'),
      headers: {...await _auth(), 'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name,
        'origin_device': originDevice,
        'origin_platform': originPlatform,
      }),
    );
    if (res.statusCode != 201) {
      throw Exception('create synced folder failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return (
      SyncedFolderInfo.fromJson(body['folder'] as Map<String, Object?>),
      body['node_id'] as String,
    );
  }

  @override
  Future<String> makeSubfolder(String parentNodeId, String name) async {
    final res = await http.post(
      _session.api('/v1/files/folder'),
      headers: {...await _auth(), 'Content-Type': 'application/json'},
      body: jsonEncode({'parent_id': parentNodeId, 'name': name}),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('mkdir failed: HTTP ${res.statusCode}');
    }
    return (jsonDecode(res.body) as Map<String, Object?>)['id'] as String;
  }

  @override
  Future<String> uploadInto(
      String parentNodeId, String name, Stream<List<int>> bytes, int length) async {
    final uri = _session.api('/v1/files/upload')
        .replace(queryParameters: {'parent': parentNodeId, 'name': name});
    final req = http.StreamedRequest('POST', uri)
      ..headers.addAll(await _auth())
      ..contentLength = length;
    // Pump the file's byte stream into the request body.
    bytes.listen(req.sink.add,
        onDone: req.sink.close, onError: (Object e) => req.sink.addError(e));
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 200) {
      throw Exception('upload failed: HTTP ${res.statusCode}');
    }
    return (jsonDecode(res.body) as Map<String, Object?>)['id'] as String;
  }

  @override
  Future<void> touch(String id,
      {required int fileCount, required int totalBytes}) async {
    await http.post(
      _session.api('/v1/synced-folders/$id/touch'),
      headers: {...await _auth(), 'Content-Type': 'application/json'},
      body: jsonEncode({'file_count': fileCount, 'total_bytes': totalBytes}),
    );
  }

  @override
  Future<void> delete(String id) async {
    final res = await http.delete(_session.api('/v1/synced-folders/$id'),
        headers: await _auth());
    if (res.statusCode != 200) {
      throw Exception('delete failed: HTTP ${res.statusCode}');
    }
  }
}
