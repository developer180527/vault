import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../capability/capability.dart';
import '../logging/vault_log.dart';
import 'http_file_repository.dart';
import 'http_jobs_api.dart';
import 'http_music_api.dart';
import 'vault_client.dart';

final _log = VaultLog.tag('client.http');

/// The real Vault server, over HTTPS inside the tailnet.
///
/// M2 scope: the capability manifest (which drives ALL navigation) is served
/// live from vaultd. Files and jobs still run on the in-process mock until
/// their server endpoints land (M3/M5) — the seam makes that swap invisible
/// to every feature.
class HttpVaultClient implements VaultClient {
  HttpVaultClient(this._ref)
      : _jobs = HttpJobsApi(_ref),
        _files = HttpFileRepository(_ref),
        _music = HttpMusicApi(_ref);

  final Ref _ref;
  final HttpJobsApi _jobs;
  final HttpFileRepository _files;
  final HttpMusicApi _music;

  @override
  FileRepository get files => _files;

  @override
  VaultJobsApi get jobs => _jobs;

  @override
  MusicApi get music => _music;

  @override
  Future<CapabilityManifest> fetchManifest() async {
    final res = await _authedGet('/v1/manifest');
    final body = jsonDecode(res.body) as Map<String, Object?>;
    final manifest = parseManifest(body);
    // Surface the server-known identity on the You page.
    final username = body['username'] as String? ?? '';
    _ref.read(sessionProvider.notifier).noteUsername(username);
    _log.info('manifest fetched', fields: {
      'services': manifest.capabilities.length,
      'user': username,
    });
    return manifest;
  }

  @override
  Future<Uint8List?> myAvatar() async {
    try {
      final res = await _authedGet('/v1/me/avatar');
      return res.bodyBytes;
    } catch (_) {
      return null; // none set (404) or transient failure — show the fallback
    }
  }

  @override
  Future<void> setMyAvatar(Uint8List bytes) async {
    var session = _ref.read(sessionProvider).asData?.value;
    if (session == null) throw Exception('not connected to a server');
    if (session.accessExpires.isBefore(DateTime.now())) {
      session = await _ref.read(sessionProvider.notifier).refresh();
      if (session == null) throw Exception('session revoked');
    }
    final res = await http.put(session.api('/v1/me/avatar'),
        headers: _auth(session), body: bytes);
    if (res.statusCode != 200) {
      throw Exception('avatar upload failed: HTTP ${res.statusCode}');
    }
  }

  /// GET with bearer auth; on 401 refreshes once and retries. A refresh that
  /// itself 401s clears the session (device revoked) — the app falls back to
  /// the disconnected state.
  Future<http.Response> _authedGet(String path) async {
    var session = _ref.read(sessionProvider).asData?.value;
    if (session == null) {
      throw Exception('not connected to a server');
    }
    // Refresh ahead of a known-expired token to save a round trip.
    if (session.accessExpires.isBefore(DateTime.now())) {
      session = await _ref.read(sessionProvider.notifier).refresh();
      if (session == null) throw Exception('session revoked');
    }

    var res = await http.get(session.api(path), headers: _auth(session));
    if (res.statusCode == 401) {
      session = await _ref.read(sessionProvider.notifier).refresh();
      if (session == null) throw Exception('session revoked');
      res = await http.get(session.api(path), headers: _auth(session));
    }
    if (res.statusCode != 200) {
      throw Exception('$path: HTTP ${res.statusCode}');
    }
    return res;
  }

  Map<String, String> _auth(Session s) =>
      {'Authorization': 'Bearer ${s.accessToken}'};

  @override
  void dispose() {}
}

/// Parses vaultd's /v1/manifest JSON into the client model. Kept as a free
/// function so it's trivially unit-testable.
CapabilityManifest parseManifest(Map<String, Object?> j) {
  final rawCaps = (j['capabilities'] as Map<String, Object?>? ?? const {});
  final caps = <String, Capability>{};
  rawCaps.forEach((serviceId, v) {
    final actionNames =
        ((v as Map<String, Object?>)['actions'] as List<Object?>? ?? const [])
            .cast<String>();
    caps[serviceId] = Capability(
      serviceId: serviceId,
      actions: {
        for (final name in actionNames)
          for (final a in CapabilityAction.values)
            if (a.name == name) a,
      },
    );
  });
  return CapabilityManifest(
    deviceId: j['device_id'] as String? ?? '',
    profileId: j['profile_id'] as String? ?? '',
    capabilities: caps,
    defaultPinned:
        (j['default_pinned'] as List<Object?>? ?? const []).cast<String>(),
  );
}
