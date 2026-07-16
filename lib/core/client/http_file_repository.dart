import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../models/file_node.dart';
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
    if (s.accessExpires.isBefore(DateTime.now())) {
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
  Future<String> addLocalFile(String? parentId, String name,
      {int? size, FileMediaKind mediaKind = FileMediaKind.none}) async {
    // The server files service ingests raw bytes; the picked-file byte stream
    // is wired in M4's backup/upload work. For now this registers intent by
    // creating an empty file so the node exists (real upload arrives with the
    // upload pipeline).
    final res = await http.post(
      _session.api('/v1/files/upload').replace(
          queryParameters: {'parent': parentId ?? '', 'name': name}),
      headers: await _headers(),
      body: const <int>[],
    );
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
