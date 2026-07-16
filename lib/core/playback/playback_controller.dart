import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:video_player/video_player.dart';

import '../logging/vault_log.dart';
import '../platform/media_codec.dart';
import '../platform/platform_services.dart';
import 'playable.dart';
import 'playback_position.dart';
import 'player_registry.dart';

final _log = VaultLog.tag('playback');

/// Snapshot of everything playing. Audio is a queue (with background/lock-
/// screen support and the floating mini-player); video is a single foreground
/// session (fullscreen-only by design — PiP comes later, see
/// [PlaybackController.videoController]).
@immutable
class PlaybackState {
  const PlaybackState({
    this.queue = const [],
    this.index = 0,
    this.video,
  });

  final List<Playable> queue;
  final int index;

  /// The active video, when a video session is open.
  final Playable? video;

  /// The current AUDIO item (drives the mini-player; video never does).
  Playable? get currentAudio =>
      queue.isEmpty ? null : queue[index.clamp(0, queue.length - 1)];

  PlaybackState copyWith({
    List<Playable>? queue,
    int? index,
    Playable? Function()? video,
  }) =>
      PlaybackState(
        queue: queue ?? this.queue,
        index: index ?? this.index,
        video: video != null ? video() : this.video,
      );
}

/// THE playback machinery: one audio engine (just_audio — queue, shuffle,
/// repeat, background playback with lock-screen metadata) and one video
/// session (video_player), owned centrally so every surface — music tab,
/// server files, future movie streaming — shares transport, mini-player, and
/// audio-focus behavior.
class PlaybackController extends Notifier<PlaybackState> {
  final AudioPlayer _player = AudioPlayer();

  /// The audio engine, exposed for stream-driven UI (position, playing,
  /// shuffle/loop state). Transport COMMANDS go through this controller.
  AudioPlayer get player => _player;

  /// The active video session's controller, if any.
  ///
  /// Ownership is centralized HERE on purpose: video_player wraps AVPlayer /
  /// ExoPlayer, and native Picture-in-Picture attaches to that underlying
  /// player. When PiP lands it will be a platform-channel hook on THIS one
  /// controller — no UI code owns a player, so nothing else changes.
  VideoPlayerController? _video;
  VideoPlayerController? get videoController => _video;

  /// Registry instance id of the live video controller (leak accounting).
  int? _videoInstance;

  @override
  PlaybackState build() {
    // Pause VIDEO when the app leaves the foreground; audio deliberately keeps
    // playing (that's what background playback is for).
    final lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s != AppLifecycleState.resumed) _video?.pause();
      },
    );
    ref.onDispose(() {
      lifecycle.dispose();
      _player.dispose();
      _video?.dispose();
    });
    // Keep our index in sync when the player advances the queue itself.
    final sub = _player.currentIndexStream.listen((i) {
      if (i != null && i != state.index && i < state.queue.length) {
        state = state.copyWith(index: i);
      }
    });
    ref.onDispose(sub.cancel);
    return const PlaybackState();
  }

  // ---- audio ----

  /// Start an audio queue at [startIndex]. Sources may be local files or
  /// authenticated network streams — the engine doesn't care.
  Future<void> playAudioQueue(List<Playable> items, int startIndex) async {
    assert(items.every((p) => p.kind == PlayableKind.audio));
    state = state.copyWith(queue: items, index: startIndex);
    try {
      await _player.setAudioSources(
        [
          for (final p in items)
            AudioSource.uri(
              p.uri,
              headers: p.headers.isEmpty ? null : p.headers,
              // Drives lock-screen / notification metadata.
              tag: MediaItem(
                id: p.id,
                title: p.title,
                artist: p.subtitle.isEmpty ? null : p.subtitle,
                album: p.album.isEmpty ? 'Vault' : p.album,
              ),
            ),
        ],
        initialIndex: startIndex,
        initialPosition: Duration.zero,
      );
      await _player.play();
      _log.info('audio queue playing',
          fields: {'count': items.length, 'start': startIndex});
    } catch (e, s) {
      _log.error('audio playback failed', error: e, stackTrace: s);
    }
  }

  Future<void> togglePlay() async {
    _player.playing ? await _player.pause() : await _player.play();
  }

  Future<void> next() => _player.seekToNext();
  Future<void> previous() => _player.seekToPrevious();
  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> setVolume(double v) => _player.setVolume(v);

  Future<void> setShuffle(bool on) => _player.setShuffleModeEnabled(on);

  Future<void> cycleRepeat() async {
    final next = switch (_player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _player.setLoopMode(next);
  }

  /// Stop audio and clear the queue (dismisses the mini-player).
  Future<void> stopAudio() async {
    await _player.stop();
    state = state.copyWith(queue: const [], index: 0);
    _log.info('audio stopped, queue cleared');
  }

  // ---- video ----

  /// Open a video session: pauses audio (focus), creates and initializes the
  /// engine, resumes from the last watched position, and returns the ready
  /// controller. The UI renders it; this controller owns it. Any previous
  /// video session is closed first (so swiping video→video is safe).
  Future<VideoPlayerController> openVideo(Playable item,
      {bool autoPlay = true}) async {
    assert(item.kind == PlayableKind.video);
    await closeVideo();
    if (_player.playing) await _player.pause();

    final c = item.isNetwork
        ? VideoPlayerController.networkUrl(item.uri,
            httpHeaders: item.headers)
        : VideoPlayerController.file(File(item.uri.toFilePath()));
    // Claim ownership BEFORE the awaits: if a close races the init, closeVideo
    // still finds and tears this controller down (no orphaned audio).
    _video = c;
    _videoInstance = PlayerRegistry.open(item.id);
    state = state.copyWith(video: () => item);
    unawaited(_logPlan(item));
    try {
      await c.initialize();
      if (_video != c) throw StateError('video session superseded');

      final resume = await ref.read(playbackPositionStoreProvider).get(item.id);
      if (resume != null && resume < c.value.duration) {
        await c.seekTo(resume);
        _log.debug('video resumed',
            fields: {'id': item.id, 'at': resume.inSeconds});
      }
      if (autoPlay && _video == c) await c.play();
    } catch (e) {
      if (_video == c) await closeVideo();
      rethrow;
    }
    _log.info('video session opened', fields: {'title': item.title});
    return c;
  }

  /// Close the active video session. With [onlyIf], closes only when that item
  /// is still the active one — so a gallery page leaving the tree can't kill a
  /// session a newer page already owns.
  ///
  /// Saves the watch position, then silences → pauses → disposes (on iOS,
  /// dispose alone can leave audio running — learned the hard way).
  Future<void> closeVideo({String? onlyIf}) async {
    if (onlyIf != null && state.video?.id != onlyIf) return;
    final c = _video;
    final id = state.video?.id;
    final instance = _videoInstance;
    _video = null;
    _videoInstance = null;
    if (state.video != null) {
      state = state.copyWith(video: () => null);
    }
    if (c == null) return;
    if (id != null && c.value.isInitialized) {
      await ref
          .read(playbackPositionStoreProvider)
          .save(id, c.value.position, c.value.duration);
    }
    try {
      await c.setVolume(0);
      await c.pause();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (e) {
      _log.error('video dispose failed', error: e);
    }
    if (instance != null && id != null) PlayerRegistry.close(instance, id);
  }

  Future<void> _logPlan(Playable item) async {
    final support = await ref.read(mediaSupportProvider.future);
    final ext = item.uri.path.split('.').last.toLowerCase();
    final plan = planPlayback(MediaTrack(container: ext), support);
    _log.info('playback plan', fields: {
      'id': item.id,
      'plan': plan is DirectPlay ? 'direct' : 'transcode',
      'hwDecode': support.hardwareDecode,
    });
  }
}

final playbackProvider =
    NotifierProvider<PlaybackController, PlaybackState>(PlaybackController.new);
