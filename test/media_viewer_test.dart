import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:vault/features/media/data/local_media_library.dart';
import 'package:vault/features/media/data/media_providers.dart';
import 'package:vault/features/media/media_viewer_page.dart';

MediaItem _item(String id, MediaKind kind) => MediaItem(
      id: id,
      kind: kind,
      asset: AssetEntity(
          id: id, typeInt: kind == MediaKind.video ? 2 : 1, width: 1, height: 1),
    );

void main() {
  testWidgets('viewer opens at the tapped index with the right counter',
      (tester) async {
    final items = [
      _item('a', MediaKind.image),
      _item('b', MediaKind.image),
      _item('c', MediaKind.video),
    ];

    await tester.pumpWidget(ProviderScope(
      overrides: [
        localMediaLibraryProvider
            .overrideWithValue(const UnsupportedMediaLibrary()),
      ],
      child: MaterialApp(
        home: MediaViewerPage(items: items, initialIndex: 1),
      ),
    ));
    await tester.pump();

    // Index 1 of 3 → "2 of 3".
    expect(find.text('2 of 3'), findsOneWidget);
  });
}
