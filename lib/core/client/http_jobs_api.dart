import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../jobs/job.dart';
import '../logging/vault_log.dart';
import 'vault_client.dart';

final _log = VaultLog.tag('client.jobs');

/// Server-backed jobs API: submit/cancel/retry/clear over HTTPS, live updates
/// over the SSE stream (`GET /v1/jobs/watch`). Reconnects automatically —
/// every connection re-seeds with a full snapshot, so a dropped stream never
/// loses state.
class HttpJobsApi implements VaultJobsApi {
  HttpJobsApi(this._ref);

  final Ref _ref;

  Session get _session {
    final s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    return s;
  }

  Future<String> _accessToken() async {
    var s = _ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    if (s.accessExpires.isBefore(DateTime.now())) {
      s = await _ref.read(sessionProvider.notifier).refresh();
      if (s == null) throw Exception('session revoked');
    }
    return s.accessToken;
  }

  Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  @override
  Future<VaultJob> submit(JobRequest request) async {
    final token = await _accessToken();
    final res = await http.post(
      _session.api('/v1/jobs'),
      headers: _headers(token),
      body: jsonEncode({
        'source': request.source,
        'kind': request.kind.name,
        if (request.title != null) 'title': request.title,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('submit failed: HTTP ${res.statusCode}');
    }
    return _jobFromJson(jsonDecode(res.body) as Map<String, Object?>);
  }

  @override
  Future<void> cancel(String id) => _post('/v1/jobs/$id/cancel');

  @override
  Future<void> retry(String id) => _post('/v1/jobs/$id/retry');

  @override
  Future<void> clearFinished() => _post('/v1/jobs/clear-finished');

  Future<void> _post(String path) async {
    final token = await _accessToken();
    final res =
        await http.post(_session.api(path), headers: _headers(token));
    if (res.statusCode != 200) {
      throw Exception('$path failed: HTTP ${res.statusCode}');
    }
  }

  @override
  Stream<List<VaultJob>> watch() {
    late StreamController<List<VaultJob>> controller;
    http.Client? client;
    var closed = false;

    // Transient drops back off 2s → 4s → … → 60s (reset by a successful
    // connect); a 403 ends the stream for good — the grant is not coming
    // back mid-session, and retrying it every 2s hammered no-grant devices.
    var backoff = const Duration(seconds: 2);
    Future<void> connect() async {
      while (!closed) {
        try {
          final token = await _accessToken();
          client = http.Client();
          final req = http.Request('GET', _session.api('/v1/jobs/watch'))
            ..headers['Authorization'] = 'Bearer $token'
            ..headers['Accept'] = 'text/event-stream';
          final res = await client!.send(req);
          if (res.statusCode == 403) {
            _log.info('jobs watch refused (no grant) — not retrying');
            controller.add(const []);
            return;
          }
          if (res.statusCode != 200) {
            throw Exception('watch HTTP ${res.statusCode}');
          }
          backoff = const Duration(seconds: 2); // healthy connect → reset
          // Parse the SSE byte stream line-by-line into `data:` events.
          var buffer = '';
          await for (final chunk
              in res.stream.transform(utf8.decoder)) {
            if (closed) break;
            buffer += chunk;
            var idx = buffer.indexOf('\n\n');
            while (idx >= 0) {
              final event = buffer.substring(0, idx);
              buffer = buffer.substring(idx + 2);
              final jobs = _parseEvent(event);
              if (jobs != null) controller.add(jobs);
              idx = buffer.indexOf('\n\n');
            }
          }
        } catch (e) {
          if (!closed) {
            _log.warn('jobs stream dropped, reconnecting', fields: {'error': '$e'});
          }
        } finally {
          client?.close();
        }
        if (closed) break;
        await Future<void>.delayed(backoff);
        backoff = backoff * 2 > const Duration(seconds: 60)
            ? const Duration(seconds: 60)
            : backoff * 2;
      }
    }

    controller = StreamController<List<VaultJob>>(
      onListen: connect,
      onCancel: () {
        closed = true;
        client?.close();
      },
    );
    return controller.stream;
  }

  /// Extracts the jobs array from one SSE event block. Ignores heartbeats
  /// (comment lines) and the reconnect sentinel.
  List<VaultJob>? _parseEvent(String event) {
    for (final line in event.split('\n')) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '{}') return null;
      try {
        final obj = jsonDecode(data) as Map<String, Object?>;
        final raw = obj['jobs'] as List<Object?>? ?? const [];
        return [
          for (final j in raw) _jobFromJson(j as Map<String, Object?>),
        ];
      } catch (_) {
        return null;
      }
    }
    return null;
  }

}

VaultJob _jobFromJson(Map<String, Object?> j) => VaultJob(
      id: j['id'] as String,
      kind: JobKind.values.firstWhere((k) => k.name == j['kind'],
          orElse: () => JobKind.download),
      title: j['title'] as String? ?? '',
      source: j['source'] as String? ?? '',
      state: JobState.values.firstWhere((s) => s.name == j['state'],
          orElse: () => JobState.queued),
      progress: (j['progress'] as num?)?.toDouble() ?? 0,
      message: j['message'] as String?,
      createdAt:
          DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
    );
