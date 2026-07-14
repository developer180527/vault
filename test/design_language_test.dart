import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vault/core/platform/design/adaptive_icons.dart';
import 'package:vault/core/platform/design/design_language.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('design language: Apple on iOS/macOS, Material elsewhere', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(designLanguage, DesignLanguage.apple);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(designLanguage, DesignLanguage.apple);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(designLanguage, DesignLanguage.material);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(designLanguage, DesignLanguage.material);
  });

  test('catalog uses real SF Symbol names with sane selected variants', () {
    // The modern gear — not the legacy cog lookalike.
    expect(VaultIcons.settings.sfSymbol, 'gearshape');
    expect(VaultIcons.settings.sfSymbolSelected, 'gearshape.fill');
    // No fill variant exists for music.note: selecting must not morph it.
    expect(VaultIcons.music.sfSymbolSelected, VaultIcons.music.sfSymbol);
    // Selected fallback: none provided → same glyph, never a surprise swap.
    expect(VaultIcons.torrent.sfSymbolSelected, VaultIcons.torrent.sfSymbol);
    expect(VaultIcons.torrent.materialSelected, Icons.public);
  });

  testWidgets('AdaptiveIcon renders the Material glyph off-Apple',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(const MaterialApp(
        home: AdaptiveIcon(VaultIcons.settings, selected: true)));
    expect(find.byIcon(Icons.settings), findsOneWidget);
    // Must be reset before the body ends: the binding checks debug variables
    // before tearDown callbacks run.
    debugDefaultTargetPlatformOverride = null;
  });
}
