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

  testWidgets('desktop shell shows sidebar with all granted services',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWith(_container()));
    await tester.pumpAndSettle();

    expect(find.text('Media'), findsWidgets);
    expect(find.text('Torrent'), findsOneWidget);
    expect(find.text('My files'), findsOneWidget);
    expect(find.text('AI Chat'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);
  });

  testWidgets('mobile bottom bar shows all services when they fit',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_appWith(_container()));
    await tester.pumpAndSettle();

    // 5 services fit directly in a Material bottom bar → no hub overflow.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('More'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('mobile overflows to a searchable Services hub past five',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // A 6th service forces the hub: bar shows pinned + "More".
    final services = [
      ...vaultServices,
      ServiceDefinition(
        id: 'extra',
        label: 'Extra',
        icon: Icons.extension_outlined,
        selectedIcon: Icons.extension,
        builder: (_) => const SizedBox.shrink(),
      ),
    ];
    final container = ProviderContainer(overrides: [
      serviceRegistryProvider.overrideWithValue(services),
      localMediaLibraryProvider
          .overrideWithValue(const UnsupportedMediaLibrary()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    expect(find.text('More'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Services'), findsOneWidget); // hub app bar
    expect(find.widgetWithText(TextField, 'Search services'),
        findsOneWidget); // searchable
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
