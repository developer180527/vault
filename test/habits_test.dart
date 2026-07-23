import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault/core/habits/habits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, HabitsNotifier)> fresh() async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(habitsProvider.future);
    return (c, c.read(habitsProvider.notifier));
  }

  test('recordServer upserts, bumps count, and sorts most-recent first',
      () async {
    final (c, h) = await fresh();
    await h.recordServer('a.ts.net');
    await h.recordServer('b.ts.net');
    await h.recordServer('a.ts.net'); // reconnect to a → most recent again

    final servers = c.read(knownServersProvider);
    expect(servers.map((s) => s.host), ['a.ts.net', 'b.ts.net']);
    expect(servers.first.count, 2); // a was connected twice
  });

  test('forgetServer removes a remembered host', () async {
    final (c, h) = await fresh();
    await h.recordServer('a.ts.net');
    await h.recordServer('b.ts.net');
    await h.forgetServer('a.ts.net');
    expect(c.read(knownServersProvider).map((s) => s.host), ['b.ts.net']);
  });

  test('service opens accrue and topServiceId reflects the most-used', () async {
    final (c, h) = await fresh();
    await h.recordServiceOpen('music');
    await h.recordServiceOpen('files');
    await h.recordServiceOpen('music');
    expect(c.read(topServiceIdProvider), 'music');
    expect(c.read(habitsProvider).requireValue.lastServiceId, 'music');
  });

  test('habits persist across a restart (new container, same prefs)', () async {
    SharedPreferences.setMockInitialValues({});
    final c1 = ProviderContainer();
    await c1.read(habitsProvider.future);
    await c1.read(habitsProvider.notifier).recordServer('vault.ts.net');
    c1.dispose();

    // A fresh container reads the persisted store — the address is remembered.
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    await c2.read(habitsProvider.future);
    expect(c2.read(knownServersProvider).single.host, 'vault.ts.net');
  });
}
