import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:video_player/video_player.dart';

import '../logging/vault_log.dart';
import 'playable.dart';

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

  @override
  PlaybackState build() {
    ref.onDispose(() {
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
  /// engine, and returns the ready controller. The UI renders it; this
  /// controller owns it. Any previous video session is closed first.
  Future<VideoPlayerController> openVideo(Playable item) async {
    assert(item.kind == PlayableKind.video);
    await closeVideo();
    if (_player.playing) await _player.pause();

    final c = item.isNetwork
        ? VideoPlayerController.networkUrl(item.uri,
            httpHeaders: item.headers)
        : VideoPlayerController.file(File(item.uri.toFilePath()));
    try {
      await c.initialize();
    } catch (e) {
      await c.dispose();
      rethrow;
    }
    _video = c;
    state = state.copyWith(video: () => item);
    await c.play();
    _log.info('video session opened', fields: {'title': item.title});
    return c;
  }

  /// Close the active video session (called when the video page pops).
  Future<void> closeVideo() async {
    final c = _video;
    _video = null;
    if (state.video != null) {
      state = state.copyWith(video: () => null);
    }
    await c?.dispose();
  }
}

final playbackProvider =
    NotifierProvider<PlaybackController, PlaybackState>(PlaybackController.new);
