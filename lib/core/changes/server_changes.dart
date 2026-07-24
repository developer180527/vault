import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/session.dart';
import '../logging/vault_log.dart';

final _log = VaultLog.tag('changes');

/// The server's change feed: `GET /v1/changes/watch` (SSE) streams a map of
/// {topic: revision}. A revision means nothing by itself — clients only
/// compare it against the last one they saw; a difference means "this topic's
/// listings changed, re-fetch them". This is how an admin-panel artwork
/// upload reaches a running app: bump → topic rev ticks → the listing
/// providers watching [topicRevProvider] rebuild → fresh art_version → new
/// `?v=` art URL → every image cache busts on its own.
///
/// Mechanics mirror the jobs stream: auto-reconnect with capped backoff, and
/// every (re)connect re-seeds with a full snapshot so a dropped stream (or a
/// server restart, whose boot-seeded revs always differ) never loses a change.
final serverRevsProvider = StreamProvider<Map<String, int>>((ref) {
  // Not connected → no feed (standalone mode); reconnecting swaps sessions
  // and this provider rebuilds with the new host automatically.
  final connected = ref.watch(
    sessionProvider.select((s) => s.asData?.value != null),
  );
  if (!connected) return const Stream.empty();

  final controller = StreamController<Map<String, int>>();
  http.Client? client;
  var closed = false;

  Future<String> accessToken() async {
    var s = ref.read(sessionProvider).asData?.value;
    if (s == null) throw Exception('not connected');
    if (s.accessExpires.isBefore(DateTime.now())) {
      s = await ref.read(sessionProvider.notifier).refresh();
      if (s == null) throw Exception('session revoked');
    }
    return s.accessToken;
  }

  var backoff = const Duration(seconds: 2);
  Future<void> connect() async {
    while (!closed) {
      try {
        final token = await accessToken();
        final session = ref.read(sessionProvider).asData?.value;
        if (session == null) return;
        client = http.Client();
        final req = http.Request('GET', session.api('/v1/changes/watch'))
          ..headers['Authorization'] = 'Bearer $token'
          ..headers['Accept'] = 'text/event-stream';
        final res = await client!.send(req);
        if (res.statusCode == 404) {
          // Older server without the feed — nothing to watch, don't hammer.
          _log.info('change feed unavailable on server — not retrying');
          return;
        }
        if (res.statusCode != 200) {
          throw Exception('watch HTTP ${res.statusCode}');
        }
        backoff = const Duration(seconds: 2); // healthy connect → reset
        var buffer = '';
        await for (final chunk in res.stream.transform(utf8.decoder)) {
          if (closed) break;
          buffer += chunk;
          var idx = buffer.indexOf('\n\n');
          while (idx >= 0) {
            final revs = _parseEvent(buffer.substring(0, idx));
            buffer = buffer.substring(idx + 2);
            if (revs != null && !closed) controller.add(revs);
            idx = buffer.indexOf('\n\n');
          }
        }
      } catch (e) {
        if (!closed) {
          _log.debug('change feed dropped, reconnecting',
              fields: {'error': '$e'});
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

  controller.onListen = connect;
  ref.onDispose(() {
    closed = true;
    client?.close();
    controller.close();
  });
  return controller.stream;
});

/// One topic's revision (0 until the feed delivers). Listing providers watch
/// THIS — not the whole map — so a music bump never rebuilds movie listings.
final topicRevProvider = Provider.family<int, String>((ref, topic) {
  final revs = ref.watch(serverRevsProvider).asData?.value;
  return revs?[topic] ?? 0;
});

/// Extracts the rev map from one SSE event block. Heartbeat comments and the
/// reconnect sentinel parse to null and are skipped.
Map<String, int>? _parseEvent(String event) {
  for (final line in event.split('\n')) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '{}') return null;
    try {
      final obj = jsonDecode(data) as Map<String, Object?>;
      return {
        for (final e in obj.entries)
          if (e.value is num) e.key: (e.value as num).toInt(),
      };
    } catch (_) {
      return null;
    }
  }
  return null;
}
