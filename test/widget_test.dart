import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vault/app.dart';
import 'package:vault/core/capability/capability.dart';
import 'package:vault/core/capability/manifest_providers.dart';
import 'package:vault/core/services/service_registry.dart';
import 'package:vault/features/media/data/local_media_library.dart';
import 'package:vault/features/media/data/media_providers.dart';

/// Media uses the real photo-library plugin, which isn't available under
/// `flutter test`; swap in the unsupported library so the shell renders.
final _testOverrides = [
  serviceRegistryProvider.overrideWithValue(vaultServices),
  localMediaLibraryProvider.overrideWithValue(const UnsupportedMediaLibrary()),
];

ProviderContainer _container() => ProviderContainer(overrides: _testOverrides);

Widget _appWith(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const VaultApp(),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('desktop sidebar shows pinned + always-available services',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWith(_container()));
    await tester.pumpAndSettle();

    // Default pins (mock manifest: first 4) + always-available Settings/You.
    expect(find.text('Media'), findsWidgets);
    expect(find.text('My files'), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Torrent'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);
    // Unpinned services launch from the You page, not the sidebar.
    expect(find.text('AI Chat'), findsNothing);
  });

  testWidgets('mobile dock shows pinned services plus the fixed You slot',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWith(_container()));
    await tester.pumpAndSettle();

    // The dock is a static row of the default pins (mock manifest: first 4)
    // plus the anchored You avatar. Nothing scrolls.
    expect(find.text('My files'), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Torrent'), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
    expect(find.byType(ListWheelScrollView), findsNothing);
    // Unpinned services and Settings are not dock destinations (You page).
    expect(find.text('AI Chat'), findsNothing);
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('You page launches unpinned services full-screen (dock hidden)',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWith(_container()));
    await tester.pumpAndSettle();

    // Open the You page from the anchored avatar slot.
    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'You'), findsOneWidget);

    // AI Chat is unpinned by default (mock manifest pins the first four), so
    // it launches over the shell: no dock, its own app bar.
    // (The filled person icon is the dock's active You avatar — its presence
    // is the "dock is visible" marker below.)
    await tester.tap(find.text('AI Chat'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'AI Chat'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsNothing); // dock hidden

    // Back returns to the shell with the dock restored.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.person), findsOneWidget);

    // The gear on the You page opens Settings full-screen the same way.
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsNothing); // dock hidden
  });

  testWidgets('phone in landscape keeps the bottom-nav shell (not desktop)',
      (tester) async {
    // Landscape phone: width 850 exceeds the desktop breakpoint, but the
    // shortest side (390) marks it a phone → must stay on the mobile shell.
    tester.view.physicalSize = const Size(850, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWith(_container()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.person_outline), findsOneWidget); // mobile dock
    expect(find.text('Trash'), findsNothing); // desktop-only sidebar item
  });

  testWidgets('tapping a pinned dock service switches the active branch',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWith(_container()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('My files'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'My files'), findsOneWidget);
  });

  testWidgets('right-clicking a file opens ONE menu, with kind-aware actions',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWith(_container()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My files'));
    await tester.pumpAndSettle();

    // Secondary-tap a document row: its item menu appears (document open
    // verb + common actions), and the enclosing empty-space region must NOT
    // also fire (that double-fired when the region listened on tap-DOWN).
    await tester.tap(find.text('Tax Return 2025.pdf'),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Open Document'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('New Folder'), findsNothing); // empty-space menu absent
  });

  testWidgets('paste-a-link submits a job that runs to completion',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    // Torrent is pinned by default and is now a direct page (magnets); URL
    // downloads live in the separate Downloads service.
    await tester.tap(find.text('Torrent'));
    await tester.pumpAndSettle();
    expect(find.text('No torrents yet'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add torrent'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField), 'magnet:?xt=urn:btih:abc&dn=My+Movie');
    await tester.tap(find.text('Add'));
    await tester.pump();

    // The scheduler picks it up automatically and drives it to done. Pump
    // fixed steps: pumpAndSettle would stop between progress ticks (a pending
    // timer schedules no frame until it fires).
    await tester.pumpAndSettle();
    expect(find.text('My Movie'), findsOneWidget);
    for (var i = 0;
        i < 100 &&
            tester.widgetList(find.byIcon(Icons.check_circle_outline)).isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('revoking a service in the manifest removes it from navigation',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();
    expect(find.text('Torrent'), findsOneWidget);

    // Server (mock) revokes the torrent grant.
    container.read(mockManifestProvider.notifier).setServiceGranted(
          'torrent',
          false,
        );
    await tester.pumpAndSettle();
    expect(find.text('Torrent'), findsNothing);
  });

  test('manifest gates actions and fails closed', () async {
    final container = _container();
    addTearDown(container.dispose);

    // Grant torrent but only read; revoke files entirely.
    final notifier = container.read(mockManifestProvider.notifier);
    notifier.setServiceGranted('torrent', true);
    notifier.setAction('torrent', CapabilityAction.write, false);
    notifier.setServiceGranted('files', false);

    // The async manifest mirrors the mock on a microtask — let it resolve.
    await container.read(manifestProvider.future);

    final canWrite = container.read(canProvider(
        (serviceId: 'torrent', action: CapabilityAction.write)));
    final canRead = container.read(
        canProvider((serviceId: 'torrent', action: CapabilityAction.read)));
    final revoked = container.read(
        canProvider((serviceId: 'files', action: CapabilityAction.read)));

    expect(canWrite, isFalse);
    expect(canRead, isTrue);
    expect(revoked, isFalse); // revoked service → all actions denied
  });
}
