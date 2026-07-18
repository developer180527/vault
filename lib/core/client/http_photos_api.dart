import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../models/server_photo.dart';
import 'vault_client.dart';

/// vaultd's photo-backup API (/v1/photos): hash-check, streamed original
/// upload, and the stored listing.
class HttpPhotosApi implements PhotosApi {
  HttpPhotosApi(this._ref);

  final Ref _ref;

  Session get _session {
    final s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    return s;
  }

  Future<Map<String, String>> _authHeaders() async {
    var s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    if (s.accessExpires.isBefore(DateTime.now())) {
      s = await _ref.read(sessionProvider.notifier).refresh();
      if (s == null) throw Exception('session revoked');
    }
    return {'Authorization': 'Bearer ${s.accessToken}'};
  }

  @override
  Future<List<String>> checkMissing(List<String> hashes) async {
    final res = await http.post(
      _session.api('/v1/photos/check'),
      headers: {...await _authHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode({'hashes': hashes}),
    );
    if (res.statusCode != 200) {
      throw Exception('photos check failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return [for (final h in (body['missing'] as List?) ?? const []) h as String];
  }

  @override
  Future<ServerPhoto> upload({
    required String path,
    required String name,
    required String hash,
    DateTime? takenAt,
  }) async {
    final req = http.MultipartRequest('POST', _session.api('/v1/photos'))
      ..headers.addAll(await _authHeaders())
      ..fields['hash'] = hash;
    if (takenAt != null) {
      req.fields['taken_at'] =
          (takenAt.millisecondsSinceEpoch ~/ 1000).toString();
    }
    // Streamed from disk: a multi-GB video never sits in memory.
    final file = File(path);
    req.files.add(http.MultipartFile(
      'file',
      file.openRead(),
      await file.length(),
      filename: name,
    ));
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('photo upload failed: HTTP ${res.statusCode}');
    }
    return ServerPhoto.fromJson(jsonDecode(res.body) as Map<String, Object?>);
  }

  @override
  Future<PhotoBackupListing> list({int limit = 200, int offset = 0}) async {
    final uri = _session.api('/v1/photos').replace(
      queryParameters: {'limit': '$limit', 'offset': '$offset'},
    );
    final res = await http.get(uri, headers: await _authHeaders());
    if (res.statusCode != 200) {
      throw Exception('photos list failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return PhotoBackupListing(
      photos: [
        for (final p in (body['photos'] as List?) ?? const [])
          ServerPhoto.fromJson(p as Map<String, Object?>),
      ],
      total: (body['total'] as num?)?.toInt() ?? 0,
      totalBytes: (body['total_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}
