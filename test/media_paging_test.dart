import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:vault/features/media/data/local_media_library.dart';
import 'package:vault/features/media/data/media_providers.dart';

/// Serves [total] fake items in pages, recording requested page numbers.
class _PagedFakeLibrary implements LocalMediaLibrary {
  _PagedFakeLibrary(this.total);

  final int total;
  final requestedPages = <int>[];

  @override
  bool get isSupported => true;

  @override
  Future<MediaAccess> requestAccess() async => MediaAccess.authorized;

  @override
  Future<void> openSettings() async {}

  @override
  Future<void> presentLimitedPicker() async {}

  @override
  Future<List<MediaItem>> loadPage({
    required MediaFilter filter,
    required int page,
    int pageSize = 120,
  }) async {
    requestedPages.add(page);
    final start = page * pageSize;
    return [
      for (var i = start; i < (start + pageSize).clamp(0, total); i++)
        MediaItem(
          id: '$filter-$i',
          kind: MediaKind.image,
          asset: AssetEntity(id: '$i', typeInt: 1, width: 1, height: 1),
        ),
    ];
  }

  @override
  Future<Uint8List?> thumbnail(MediaItem item, {int size = 300}) async => null;

  @override
  Future<Uint8List?> fullImage(MediaItem item) async => null;

  @override
  Future<String?> videoPath(MediaItem item) async => null;
}

void main() {
  // Riverpod 3 pauses providers nobody listens to, so every test holds a
  // subscription open and settles states by pumping microtasks.
  ProviderContainer container(_PagedFakeLibrary lib) {
    final c = ProviderContainer(overrides: [
      localMediaLibraryProvider.overrideWithValue(lib),
    ]);
    addTearDown(c.dispose);
    final sub = c.listen(mediaItemsProvider, (_, _) {});
    addTearDown(sub.close);
    return c;
  }

  Future<List<MediaItem>> whenLength(ProviderContainer c, int n) async {
    for (var i = 0; i < 200; i++) {
      final v = c.read(mediaItemsProvider).asData?.value;
      if (v != null && v.length == n) return v;
      await Future<void>.delayed(Duration.zero);
    }
    fail('items never reached length $n; last: ${c.read(mediaItemsProvider)}');
  }

  test('grid is no longer capped: pages accumulate to the full library',
      () async {
    final lib = _PagedFakeLibrary(250);
    final c = container(lib);

    await whenLength(c, 120); // page 0
    await c.read(mediaItemsProvider.notifier).loadMore();
    await whenLength(c, 240); // + page 1
    await c.read(mediaItemsProvider.notifier).loadMore();
    await whenLength(c, 250); // + short page 2 = end

    // End reached: further calls are no-ops (no page 3 request).
    await c.read(mediaItemsProvider.notifier).loadMore();
    expect(c.read(mediaItemsProvider).requireValue.length, 250);
    expect(lib.requestedPages, [0, 1, 2]);
  });

  test('changing the filter resets paging to page 0', () async {
    final lib = _PagedFakeLibrary(300);
    final c = container(lib);

    await whenLength(c, 120);
    await c.read(mediaItemsProvider.notifier).loadMore();
    await whenLength(c, 240);

    c.read(mediaFilterProvider.notifier).set(MediaFilter.videos);
    final items = await whenLength(c, 120); // fresh page 0, new filter
    expect(items.first.id, startsWith('MediaFilter.videos'));
  });

  test('loadMore keeps existing items when a page fetch fails', () async {
    final lib = _ThrowingSecondPageLibrary();
    final c = container(lib);

    await whenLength(c, 120);
    await c.read(mediaItemsProvider.notifier).loadMore(); // throws internally
    expect(c.read(mediaItemsProvider).requireValue.length, 120); // kept
  });
}

class _ThrowingSecondPageLibrary extends _PagedFakeLibrary {
  _ThrowingSecondPageLibrary() : super(500);

  @override
  Future<List<MediaItem>> loadPage({
    required MediaFilter filter,
    required int page,
    int pageSize = 120,
  }) {
    if (page > 0) throw StateError('boom');
    return super.loadPage(filter: filter, page: page, pageSize: pageSize);
  }
}
