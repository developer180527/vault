import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import 'vault_client.dart';

/// The Administrative API: resumable content upload for the shared library.
///
/// One protocol for both kinds (`music` | `movies`), matching the server's
/// `/v1/admin/uploads/*`. A 10 GB single POST is all-or-nothing, so transfers
/// are chunked: a dropped connection costs one chunk, the server's offset is
/// authoritative, and an upload resumes days later if need be.
class HttpAdminApi implements AdminApi {
  HttpAdminApi(this._ref);

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
  Future<String> beginUpload({
    required String kind,
    required String name,
    required int size,
  }) async {
    final res = await http.post(
      _session.api('/v1/admin/uploads'),
      headers: {...await _auth(), 'Content-Type': 'application/json'},
      body: jsonEncode({'kind': kind, 'name': name, 'size': size}),
    );
    if (res.statusCode != 201) {
      throw Exception('begin upload failed: HTTP ${res.statusCode} ${res.body}');
    }
    return (jsonDecode(res.body) as Map<String, Object?>)['id'] as String;
  }

  @override
  Future<int> uploadOffset(String uploadId) async {
    final res = await http.get(_session.api('/v1/admin/uploads/$uploadId'),
        headers: await _auth());
    if (res.statusCode != 200) {
      throw Exception('upload offset failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return (body['offset'] as num).toInt();
  }

  @override
  Future<int> uploadChunk(String uploadId, int offset, List<int> chunk) async {
    final req =
        http.Request('PATCH', _session.api('/v1/admin/uploads/$uploadId'))
          ..headers.addAll(await _auth())
          ..headers['Upload-Offset'] = '$offset'
          ..headers['Content-Type'] = 'application/offset+octet-stream'
          ..bodyBytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode == 409) {
      // The server tells us where it actually is, so we re-sync in one trip.
      final body = jsonDecode(res.body) as Map<String, Object?>;
      throw UploadOffsetConflict((body['offset'] as num).toInt());
    }
    if (res.statusCode != 200) {
      throw Exception('chunk failed: HTTP ${res.statusCode}');
    }
    return ((jsonDecode(res.body) as Map<String, Object?>)['offset'] as num)
        .toInt();
  }

  @override
  Future<void> finishUpload(String uploadId) async {
    final res = await http.post(
        _session.api('/v1/admin/uploads/$uploadId/finish'),
        headers: await _auth());
    if (res.statusCode != 200) {
      throw Exception('finish failed: HTTP ${res.statusCode} ${res.body}');
    }
  }

  @override
  Future<void> abortUpload(String uploadId) async {
    await http.delete(_session.api('/v1/admin/uploads/$uploadId'),
        headers: await _auth());
  }

  @override
  Future<List<RemoteUpload>> pendingUploads() async {
    final res =
        await http.get(_session.api('/v1/admin/uploads'), headers: await _auth());
    if (res.statusCode != 200) {
      throw Exception('list uploads failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return [
      for (final u in (body['uploads'] as List?) ?? const [])
        RemoteUpload.fromJson(u as Map<String, Object?>),
    ];
  }
}
