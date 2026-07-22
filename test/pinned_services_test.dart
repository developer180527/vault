import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault/core/prefs/pinned_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, PinnedServicesNotifier)> load(
      List<String> stored) async {
    // A stored list short-circuits build() (no manifest/registry needed).
    SharedPreferences.setMockInitialValues({'pinned_services_v1': stored});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(pinnedServicesProvider.future);
    return (c, c.read(pinnedServicesProvider.notifier));
  }

  test('cap counts only dockable pins — a non-permitted pin never wedges it',
      () async {
    // 4 stored pins, but 'files' isn't currently a dockable service, so the
    // dock shows 3. Before the fix, current.length (4) tripped the cap and
    // refused a 4th visible pin ("only pins 3, says max 4").
    final (c, q) = await load(['media', 'music', 'movies', 'files']);
    const dockable = {'media', 'music', 'movies', 'torrent'};

    final ok = await q.toggle('torrent', maxPins: 4, countAmong: dockable);
    expect(ok, isTrue, reason: '3 dockable pins < cap of 4');
    expect(c.read(pinnedServicesProvider).requireValue, contains('torrent'));
  });

  test('cap still blocks a 5th DOCKABLE pin', () async {
    final (_, q) = await load(['media', 'music', 'movies', 'torrent']);
    const dockable = {'media', 'music', 'movies', 'torrent', 'files'};

    final ok = await q.toggle('files', maxPins: 4, countAmong: dockable);
    expect(ok, isFalse, reason: '4 dockable pins already at the cap');
  });

  test('unpinning is never capped', () async {
    final (c, q) = await load(['media', 'music', 'movies', 'torrent']);
    final ok = await q.toggle('music', maxPins: 4, countAmong: {'music'});
    expect(ok, isTrue);
    expect(
        c.read(pinnedServicesProvider).requireValue, isNot(contains('music')));
  });
}
