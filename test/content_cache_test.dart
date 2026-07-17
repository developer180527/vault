import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:vault/core/cache/content_cache.dart';
import 'package:vault/core/models/server_track.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_cache_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('keyFor is stable and filename-safe', () {
    final k1 = ContentCache.keyFor('https://vault/v1/music/catalog/abc/art');
    final k2 = ContentCache.keyFor('https://vault/v1/music/catalog/abc/art');
    final k3 = ContentCache.keyFor('https://vault/v1/music/catalog/xyz/art');
    expect(k1, k2);
    expect(k1, isNot(k3));
    expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(k1), isTrue);
  });

  test('snapshot round-trips through the models', () async {
    final cache = ContentCache(root: tmp);
    const tracks = [
      ServerTrack(id: 'a', title: 'One', artist: 'X', hasArt: true),
      ServerTrack(id: 'b', title: 'Two', album: 'Al', year: 2001),
    ];
    await cache.writeSnapshot(
        'music.catalog', jsonEncode([for (final t in tracks) t.toJson()]));

    final back = await cache.readSnapshot('music.catalog');
    final decoded = [
      for (final j in jsonDecode(back!) as List)
        ServerTrack.fromJson(j as Map<String, Object?>),
    ];
    expect(decoded, hasLength(2));
    expect(decoded[0].id, 'a');
    expect(decoded[0].hasArt, isTrue);
    expect(decoded[1].album, 'Al');
    expect(decoded[1].year, 2001);

    // Unknown snapshot → null, not an error.
    expect(await cache.readSnapshot('nope'), isNull);
  });

  test('image: network once, then disk/memory; auth header sent', () async {
    var hits = 0;
    final client = MockClient((req) async {
      hits++;
      expect(req.headers['Authorization'], 'Bearer tok');
      return http.Response.bytes([1, 2, 3], 200,
          headers: {'etag': '"v1"'});
    });
    final cache = ContentCache(root: tmp, client: client);
    final uri = Uri.parse('https://vault/v1/music/catalog/a/art');
    const auth = {'Authorization': 'Bearer tok'};

    final first = await cache.image(uri, headers: auth);
    expect(first, [1, 2, 3]);
    expect(hits, 1);

    // Memory hit: no second request.
    final second = await cache.image(uri, headers: auth);
    expect(second, [1, 2, 3]);
    expect(hits, 1);

    // Fresh instance (cold start): disk hit, still no request — and the
    // background revalidation is skipped inside the TTL.
    final cold = ContentCache(root: tmp, client: client);
    final third = await cold.image(uri, headers: auth);
    expect(third, [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(hits, 1);
  });

  test('image: non-200 is not cached', () async {
    final client = MockClient((req) async => http.Response('nope', 404));
    final cache = ContentCache(root: tmp, client: client);
    final bytes =
        await cache.image(Uri.parse('https://vault/missing/art'));
    expect(bytes, isNull);
    // Nothing persisted for the failed fetch.
    final img = Directory('${tmp.path}/img');
    if (await img.exists()) {
      expect(img.listSync().where((f) => f.path.endsWith('.bin')), isEmpty);
    }
  });
}
