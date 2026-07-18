import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../logging/vault_log.dart';

final _log = VaultLog.tag('cache');

/// THE content cache — a core system, not a music feature.
///
/// Strategy: **stale-while-revalidate**. Small content (album art, poster
/// images, listing JSON) is served from disk instantly, so a screen paints in
/// one frame even on cold start; the network copy refreshes in the background
/// and the UI catches up only if something actually changed. The heavy bytes
/// (audio/video streams) are NOT cached here — they stream; this cache makes
/// the second of stream spin-up *feel* fast because everything around it is
/// already on screen.
///
/// Two stores:
///  - **images**: memory LRU + disk, keyed by URL. Revalidated with the
///    server's ETag (`If-None-Match`) once [imageTtl] has passed — a 304
///    costs headers only.
///  - **snapshots**: last-known JSON for a listing, keyed by a caller-chosen
///    name. Consumers return the snapshot immediately and refresh behind it.
///
/// Consumers today: the music service (catalog/playlists/personal listings,
/// album art). Next: the movies service (posters, listings) — same calls.
class ContentCache {
  ContentCache({Directory? root, http.Client? client})
    : _rootOverride = root,
      _client = client ?? http.Client();

  final Directory? _rootOverride;
  final http.Client _client;

  /// Disk copies older than this are revalidated (in the background) on read.
  static const imageTtl = Duration(days: 7);

  /// Memory layer budget in BYTES — a count cap lied: 64 entries of full-size
  /// embedded covers (≈1 MB each) is ~64 MB, not "a few". 16 MB holds ~hundreds
  /// of typical covers; anything evicted is still one disk read away.
  static const _memBudgetBytes = 16 << 20;

  /// Entries bigger than this skip the memory layer entirely (disk-only) so a
  /// single giant image can't flush the whole LRU.
  static const _memEntryCapBytes = 3 << 20;

  /// Insertion-ordered → oldest first; re-inserting on hit keeps it LRU.
  final _mem = <String, Uint8List>{};
  int _memBytes = 0;

  /// Current memory-layer footprint (tests assert the budget holds).
  @visibleForTesting
  int get memoryBytes => _memBytes;

  Directory? _root;

  Future<Directory> _dir(String sub) async {
    final root = _root ??=
        _rootOverride ??
        Directory('${(await getApplicationCacheDirectory()).path}/vault_cache');
    final d = Directory('${root.path}/$sub');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// FNV-1a 64-bit hex of [s] — a stable filename for any URL/key without
  /// pulling in a crypto dependency (collision odds are irrelevant at
  /// personal-library scale).
  static String keyFor(String s) {
    var h = 0xcbf29ce484222325;
    for (final c in utf8.encode(s)) {
      h = (h ^ c) * 0x100000001b3;
      h &= 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  void _remember(String key, Uint8List bytes) {
    final old = _mem.remove(key);
    if (old != null) _memBytes -= old.length;
    if (bytes.length > _memEntryCapBytes) return; // disk-only, see cap docs
    _mem[key] = bytes;
    _memBytes += bytes.length;
    while (_memBytes > _memBudgetBytes && _mem.isNotEmpty) {
      _memBytes -= _mem.remove(_mem.keys.first)!.length;
    }
  }

  // ---- images ----

  /// Bytes for [uri]: memory → disk (instant, with background ETag
  /// revalidation once stale) → network. Null = unfetchable and no copy.
  Future<Uint8List?> image(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final key = keyFor(uri.toString());
    final mem = _mem[key];
    if (mem != null) {
      _remember(key, mem); // refresh LRU position
      return mem;
    }

    final dir = await _dir('img');
    final bin = File('${dir.path}/$key.bin');
    final meta = File('${dir.path}/$key.json');
    if (await bin.exists()) {
      try {
        final bytes = await bin.readAsBytes();
        _remember(key, bytes);
        unawaited(_revalidate(uri, headers, bin, meta, key));
        return bytes;
      } catch (_) {
        // fall through to a fresh fetch
      }
    }
    return _fetchToDisk(uri, headers, bin, meta, key);
  }

  Future<Uint8List?> _fetchToDisk(
    Uri uri,
    Map<String, String> headers,
    File bin,
    File meta,
    String key,
  ) async {
    try {
      final res = await _client.get(uri, headers: headers);
      if (res.statusCode != 200) return null;
      final bytes = res.bodyBytes;
      _remember(key, bytes);
      // Atomic-enough for a cache: temp + rename (a torn cache entry would
      // otherwise serve garbage forever).
      final tmp = File('${bin.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(bin.path);
      await meta.writeAsString(
        jsonEncode({
          'etag': res.headers['etag'] ?? '',
          'fetched_at': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      return bytes;
    } catch (e) {
      _log.debug('image fetch failed', fields: {'uri': '$uri', 'err': '$e'});
      return null;
    }
  }

  /// Background freshness check: within TTL → skip; otherwise conditional GET
  /// (ETag). 304 renews the clock for free; 200 replaces disk + memory so the
  /// NEXT view shows the update — the current frame never flickers.
  Future<void> _revalidate(
    Uri uri,
    Map<String, String> headers,
    File bin,
    File meta,
    String key,
  ) async {
    try {
      String etag = '';
      var fetchedAt = 0;
      if (await meta.exists()) {
        final m = jsonDecode(await meta.readAsString()) as Map<String, Object?>;
        etag = (m['etag'] as String?) ?? '';
        fetchedAt = (m['fetched_at'] as num?)?.toInt() ?? 0;
      }
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(fetchedAt),
      );
      if (age < imageTtl) return;

      final res = await _client.get(
        uri,
        headers: {...headers, if (etag.isNotEmpty) 'If-None-Match': etag},
      );
      if (res.statusCode == 304) {
        await meta.writeAsString(
          jsonEncode({
            'etag': etag,
            'fetched_at': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      } else if (res.statusCode == 200) {
        _remember(key, res.bodyBytes);
        final tmp = File('${bin.path}.tmp');
        await tmp.writeAsBytes(res.bodyBytes, flush: true);
        await tmp.rename(bin.path);
        await meta.writeAsString(
          jsonEncode({
            'etag': res.headers['etag'] ?? '',
            'fetched_at': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      }
    } catch (_) {
      // Revalidation is best-effort by definition.
    }
  }

  // ---- JSON snapshots ----

  /// The last saved JSON for [name], or null. Disk-fast: callers return this
  /// immediately and refresh from the network behind it.
  Future<String?> readSnapshot(String name) async {
    try {
      final f = File('${(await _dir('snap')).path}/${keyFor(name)}.json');
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> writeSnapshot(String name, String json) async {
    try {
      final f = File('${(await _dir('snap')).path}/${keyFor(name)}.json');
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      _log.debug('snapshot write failed', fields: {'name': name, 'err': '$e'});
    }
  }

  /// Wipe everything (logout / storage pressure).
  Future<void> clear() async {
    _mem.clear();
    _memBytes = 0;
    try {
      final root = _root ?? _rootOverride;
      if (root != null && await root.exists()) {
        await root.delete(recursive: true);
      }
    } catch (_) {}
  }
}

final contentCacheProvider = Provider<ContentCache>((ref) => ContentCache());
