import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'platform_info.dart';

/// The current audio OUTPUT device's display name (e.g. "iPhone Speaker",
/// "Rockerz 551 ANC Pro", "AirPods Pro"), live-updated as the route changes
/// (Bluetooth connect, AirPlay, headphones). iOS only — sourced from
/// AVAudioSession via a native channel; null elsewhere (no such concept /
/// Android surfaces it differently).
const _routeMethod = MethodChannel('vault/audio-route');
const _routeEvents = EventChannel('vault/audio-route/events');

final audioOutputNameProvider = StreamProvider<String?>((ref) async* {
  if (!isIOS) {
    yield null;
    return;
  }
  // Seed with the current route, then follow live changes.
  try {
    yield await _routeMethod.invokeMethod<String>('currentOutput');
  } catch (_) {
    yield null;
  }
  yield* _routeEvents
      .receiveBroadcastStream()
      .map((e) => e as String?)
      .handleError((_) {});
});
