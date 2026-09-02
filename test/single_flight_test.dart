import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/core/util/single_flight.dart';

void main() {
  test('concurrent callers share ONE execution', () async {
    // The reason this exists: refresh tokens are single-use and rotate on the
    // server. Two executions means the second presents a rotated-away token
    // and can get the device revoked.
    var runs = 0;
    final sf = SingleFlight<int>();
    Future<int> action() async {
      runs++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return 42;
    }

    final results = await Future.wait([sf.run(action), sf.run(action), sf.run(action)]);

    expect(runs, 1);
    expect(results, [42, 42, 42]);
  });

  test('every joined caller receives the failure', () async {
    final sf = SingleFlight<int>();
    Future<int> failing() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      throw StateError('offline');
    }

    final a = sf.run(failing);
    final b = sf.run(failing);

    await expectLater(a, throwsStateError);
    await expectLater(b, throwsStateError);
  });

  test('a failure does NOT escape as an uncaught zone error', () async {
    // THE regression. The bookkeeping used to discard the future returned by
    // whenComplete(), which mirrors the action's error. Nothing listened to
    // that copy, so an offline refresh surfaced as `FATAL Uncaught error` in
    // the logs even though the caller handled it — burying real crashes.
    final uncaught = <Object>[];

    await runZonedGuarded(() async {
      final sf = SingleFlight<int>();
      try {
        await sf.run(() async => throw StateError('offline'));
      } catch (_) {
        // Handled, exactly as the real caller handles it.
      }
      // Let any stray unhandled error reach the zone before we assert.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }, (e, _) => uncaught.add(e))!;

    expect(uncaught, isEmpty,
        reason: 'a handled failure must not also reach the zone handler');
  });

  test('the slot is released, so a later call runs again', () async {
    var runs = 0;
    final sf = SingleFlight<int>();
    Future<int> action() async {
      runs++;
      return runs;
    }

    expect(await sf.run(action), 1);
    expect(sf.isRunning, isFalse);
    // A failure must not be cached either — the next caller gets a fresh try.
    expect(await sf.run(action), 2);
    expect(runs, 2);
  });
}
