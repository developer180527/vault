import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../models/file_node.dart';
import '../playback/playable.dart';
import 'vault_client.dart';

/// Server-backed file browser over the vaultd files API. The visible root is
/// the whole library (Downloads/Photos/Music/Files zones as top-level
/// folders). Node ids are opaque server handles — never parsed here.
class HttpFileRepository implements FileRepository {
  HttpFileRepository(this._ref);

  final Ref _ref;

  Session get _session {
    final s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    return s;
  }

  /// A bearer token, refreshed if expired.
  Future<String> _token() async {
    var s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    if (s.needsRenewal) {
      s = await _ref.read(sessionProvider.notifier).refresh();
      if (s == null) throw Exception('session revoked');
    }
    return s.accessToken;
  }

  Future<Map<String, String>> _headers({bool json = false}) async => {
        'Authorization': 'Bearer ${await _token()}',
        if (json) 'Content-Type': 'application/json',
      };

  /// Public URL for streaming a node's content (used by the media players,
  /// which fetch it with the auth header).
  Uri contentUri(String id) => _session.api('/v1/files/$id/content');

  /// Stream URL for a specific embedded audio track. `audio > 0` makes the
  /// server remux with only that track (`-c copy`); a remuxed pipe can't
  /// serve Range, so the seek offset rides in the URL.
  Uri contentUriForTrack(String id, int audio, int startSec) {
    final q = <String, String>{};
    if (audio > 0) q['audio'] = '$audio';
    if (startSec > 0) q['start'] = '$startSec';
    final base = _session.api('/v1/files/$id/content');
    return q.isEmpty ? base : base.replace(queryParameters: q);
  }

  /// What's inside a video: audio/subtitle tracks, codec, dimensions. The
  /// server probes on demand and caches by (path, size, mtime). Returns an
  /// empty list of tracks for anything not probeable.
  Future<List<AudioTrackOption>> audioTracks(String id) async {
    try {
      final res = await http.get(_session.api('/v1/files/$id/mediainfo'),
          headers: await _headers());
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body) as Map<String, Object?>;
      final streams = (body['streams'] as Map<String, Object?>?) ?? const {};
      final audio = (streams['audio'] as List?) ?? const [];
      return [
        for (final a in audio)
          AudioTrackOption(
            index: ((a as Map<String, Object?>)['index'] as num?)?.toInt() ?? 0,
            label: _trackLabel(a),
            isDefault: (a['default'] as bool?) ?? false,
          ),
      ];
    } catch (_) {
      return const []; // never block playback on track discovery
    }
  }

  /// "English Dub" › "English 5.1" › "Track 2" — never blank.
  static String _trackLabel(Map<String, Object?> a) {
    final title = (a['title'] as String?) ?? '';
    if (title.isNotEmpty) return title;
    final lang = (a['lang'] as String?) ?? '';
    final ch = (a['channels'] as num?)?.toInt() ?? 0;
    final suffix = ch == 6 ? ' 5.1' : (ch == 8 ? ' 7.1' : '');
    final idx = ((a['index'] as num?)?.toInt() ?? 0) + 1;
    return lang.isEmpty ? 'Track $idx' : '${lang.toUpperCase()}$suffix';
  }

  /// The bearer header for streaming requests.
  Future<Map<String, String>> authHeader() => _headers();

  @override
  Future<List<FileNode>> children(String? parentId) async {
    final res = await http.get(
      _session.api('/v1/files').replace(
          queryParameters: parentId == null ? null : {'id': parentId}),
      headers: await _headers(),
    );
    _check(res, 'list');
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return _nodes(body['nodes'], fallbackParent: parentId);
  }

  @override
  Future<FileNode?> node(String id) async {
    // Derive from the parent listing is overkill; the path endpoint returns
    // the chain whose last element is this node.
    final chain = await pathTo(id);
    return chain.isEmpty ? null : chain.last;
  }

  @override
  Future<List<FileNode>> pathTo(String id) async {
    final res = await http.get(
      _session.api('/v1/files/path').replace(queryParameters: {'id': id}),
      headers: await _headers(),
    );
    _check(res, 'path');
    final body = jsonDecode(res.body) as Map<String, Object?>;
    return _nodes(body['nodes']);
  }

  @override
  Future<String> createFolder(String? parentId, String name) async {
    final res = await http.post(
      _session.api('/v1/files/folder'),
      headers: await _headers(json: true),
      body: jsonEncode({'parent_id': parentId ?? '', 'name': name}),
    );
    _check(res, 'mkdir');
    return (jsonDecode(res.body) as Map<String, Object?>)['id'] as String;
  }

  @override
  Future<String> uploadFile(
      String? parentId, String name, Stream<List<int>> bytes, int length,
      {FileMediaKind mediaKind = FileMediaKind.none}) async {
    // Stream the real bytes to the server (the handler reads r.Body directly).
    // A StreamedRequest pumps the file through without buffering it in memory.
    final uri = _session.api('/v1/files/upload').replace(
        queryParameters: {'parent': parentId ?? '', 'name': name});
    final req = http.StreamedRequest('POST', uri)
      ..headers.addAll(await _headers())
      ..contentLength = length;
    bytes.listen(req.sink.add,
        onDone: req.sink.close,
        onError: (Object e) => req.sink.addError(e),
        cancelOnError: true);
    final res = await http.Response.fromStream(await req.send());
    _check(res, 'upload');
    return (jsonDecode(res.body) as Map<String, Object?>)['id'] as String;
  }

  @override
  Future<void> rename(String id, String newName) async {
    final res = await http.post(
      _session.api('/v1/files/rename'),
      headers: await _headers(json: true),
      body: jsonEncode({'id': id, 'name': newName}),
    );
    _check(res, 'rename');
  }

  @override
  Future<String> move(String id, String? destParentId) =>
      _transfer('move', id, destParentId);

  @override
  Future<String> copy(String id, String? destParentId) =>
      _transfer('copy', id, destParentId);

  Future<String> _transfer(String op, String id, String? destParentId) async {
    final res = await http.post(
      _session.api('/v1/files/$op'),
      headers: await _headers(json: true),
      body: jsonEncode({'id': id, 'dest_parent': destParentId ?? ''}),
    );
    _check(res, op);
    return (jsonDecode(res.body) as Map<String, Object?>)['id'] as String;
  }

  @override
  bool get supportsPinning => false; // sync/mirror lands M-later

  @override
  Future<void> setPinned(String id, bool pinned) async {
    // Unreachable while supportsPinning is false (the UI hides the action).
  }

  @override
  Future<void> trash(String id) async {
    final res = await http.post(
      _session.api('/v1/files/trash'),
      headers: await _headers(json: true),
      body: jsonEncode({'id': id}),
    );
    _check(res, 'trash');
  }

  void _check(http.Response res, String op) {
    if (res.statusCode != 200) {
      throw Exception('files $op failed: HTTP ${res.statusCode}');
    }
  }

  List<FileNode> _nodes(Object? raw, {String? fallbackParent}) {
    final list = (raw as List<Object?>? ?? const []);
    return [
      for (final j in list) _node(j as Map<String, Object?>, fallbackParent),
    ];
  }

  FileNode _node(Map<String, Object?> j, String? fallbackParent) {
    final kind =
        j['kind'] == 'folder' ? NodeKind.folder : NodeKind.file;
    return FileNode(
      id: j['id'] as String,
      parentId: (j['parent_id'] as String?) ?? fallbackParent,
      name: j['name'] as String,
      kind: kind,
      // Server files are authoritative + present; no local mirror yet.
      syncStatus: SyncStatus.available,
      mediaKind: _mediaKind(j['media_kind'] as String?),
      size: (j['size'] as num?)?.toInt(),
      modifiedAt: DateTime.tryParse(j['modified_at'] as String? ?? ''),
      childCount: (j['child_count'] as num?)?.toInt(),
    );
  }

  FileMediaKind _mediaKind(String? s) => switch (s) {
        'image' => FileMediaKind.image,
        'video' => FileMediaKind.video,
        'audio' => FileMediaKind.audio,
        'document' => FileMediaKind.document,
        _ => FileMediaKind.none,
      };
}
