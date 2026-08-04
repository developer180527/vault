import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../../../core/playback/mpv_engine.dart';

/// The transport surface the video chrome talks to, independent of which
/// engine is actually decoding.
///
/// Why this exists: the app runs TWO video engines — `video_player`
/// (AVPlayer/ExoPlayer) and libmpv — and the user must not be able to tell
/// which one they got. Before this, the controls were welded to
/// [VideoPlayerController], so the libmpv page had to grow its own parallel
/// (and visibly different) chrome. Everything the controls need is right here;
/// each engine adapts to it once.
///
/// It's a [Listenable] so the chrome rebuilds on the engine's own signal —
/// no polling, same as [VideoPlayerController]'s ValueNotifier.
abstract class VideoTransport implements Listenable {
  bool get isPlaying;
  bool get isBuffering;
  Duration get position;
  Duration get duration;

  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration to);

  /// Seek by a delta, clamped to the media — the ±10s/±60s controls and the
  /// keyboard shortcuts all funnel through here so the clamping is written
  /// once rather than in each caller.
  Future<void> seekBy(Duration by) {
    var target = position + by;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    return seekTo(target);
  }

  Future<void> togglePlay() => isPlaying ? pause() : play();
}

/// [VideoTransport] over `video_player`. Pure delegation: the controller is
/// already a ValueNotifier, so listener registration passes straight through
/// and no extra rebuild plumbing is introduced.
class VideoPlayerTransport implements VideoTransport {
  const VideoPlayerTransport(this.controller);

  final VideoPlayerController controller;

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);

  @override
  bool get isPlaying => controller.value.isPlaying;
  @override
  bool get isBuffering => controller.value.isBuffering;
  @override
  Duration get position => controller.value.position;
  @override
  Duration get duration => controller.value.duration;

  @override
  Future<void> play() => controller.play();
  @override
  Future<void> pause() => controller.pause();
  @override
  Future<void> seekTo(Duration to) => controller.seekTo(to);

  @override
  Future<void> seekBy(Duration by) => _seekBy(this, by);
  @override
  Future<void> togglePlay() => isPlaying ? pause() : play();
}

/// [VideoTransport] over libmpv ([MpvEngine]).
///
/// mpv reports state through streams rather than a notifier, so this collapses
/// them into one [ChangeNotifier]. Position is kept as a field because the
/// chrome reads it synchronously during build.
class MpvTransport extends ChangeNotifier implements VideoTransport {
  MpvTransport(this._engine) {
    _subs.add(_engine.stateStream.listen((_) => notifyListeners()));
    _subs.add(_engine.positionStream.listen((p) {
      _position = p;
      notifyListeners();
    }));
  }

  final MpvEngine _engine;
  final List<StreamSubscription<Object?>> _subs = [];
  Duration _position = Duration.zero;

  @override
  bool get isPlaying => _engine.state.playing;
  @override
  bool get isBuffering => _engine.state.buffering;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _engine.state.duration;

  @override
  Future<void> play() => _engine.play();
  @override
  Future<void> pause() => _engine.pause();
  @override
  Future<void> seekTo(Duration to) => _engine.seek(to);

  @override
  Future<void> seekBy(Duration by) => _seekBy(this, by);
  @override
  Future<void> togglePlay() => isPlaying ? pause() : play();

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }
}

/// Shared clamped-seek used by both adapters (Dart has no mixin-with-default
/// on an `implements` relationship, so the body lives here once).
Future<void> _seekBy(VideoTransport t, Duration by) {
  var target = t.position + by;
  if (target < Duration.zero) target = Duration.zero;
  if (t.duration > Duration.zero && target > t.duration) target = t.duration;
  return t.seekTo(target);
}
