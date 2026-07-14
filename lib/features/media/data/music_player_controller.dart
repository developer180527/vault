import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../../core/logging/vault_log.dart';
import 'music_library.dart';
import 'music_metadata.dart';

final _log = VaultLog.tag('music.player');

@immutable
class MusicPlayerState {
  const MusicPlayerState({this.queue = const [], this.index = 0});

  final List<MusicTrack> queue;
  final int index;

  MusicTrack? get current =>
      queue.isEmpty ? null : queue[index.clamp(0, queue.length - 1)];

  MusicPlayerState copyWith({List<MusicTrack>? queue, int? index}) =>
      MusicPlayerState(queue: queue ?? this.queue, index: index ?? this.index);
}

/// Global audio player (survives navigation) backed by just_audio, which uses
/// the system audio APIs — no bundled native libs, sideloads cleanly.
class MusicPlayerController extends Notifier<MusicPlayerState> {
  final AudioPlayer _player = AudioPlayer();

  AudioPlayer get player => _player;

  @override
  MusicPlayerState build() {
    ref.onDispose(_player.dispose);
    // Keep our index in sync when the player advances the queue itself.
    final sub = _player.currentIndexStream.listen((i) {
      if (i != null && i != state.index && i < state.queue.length) {
        state = state.copyWith(index: i);
      }
    });
    ref.onDispose(sub.cancel);
    return const MusicPlayerState();
  }

  /// Start a queue at [startIndex].
  Future<void> playQueue(List<MusicTrack> tracks, int startIndex) async {
    state = MusicPlayerState(queue: tracks, index: startIndex);
    // Real tags when the metadata pass has finished; filename fallback if
    // the user hits play before it lands.
    final meta =
        ref.read(musicMetadataProvider).asData?.value ?? const {};
    try {
      await _player.setAudioSources(
        [
          for (final t in tracks)
            AudioSource.file(
              t.path,
              // Tag drives the lock-screen / notification metadata for
              // background playback.
              tag: MediaItem(
                id: t.id,
                title: meta[t.path]?.title ?? t.title,
                artist: meta[t.path]?.artist,
                album: meta[t.path]?.album ?? 'Local music',
              ),
            ),
        ],
        initialIndex: startIndex,
        initialPosition: Duration.zero,
      );
      await _player.play();
      _log.info('Playing queue',
          fields: {'count': tracks.length, 'start': startIndex});
    } catch (e, s) {
      _log.error('Music playback failed', error: e, stackTrace: s);
    }
  }

  Future<void> togglePlay() async {
    _player.playing ? await _player.pause() : await _player.play();
  }

  Future<void> next() => _player.seekToNext();
  Future<void> previous() => _player.seekToPrevious();

  /// Stop playback and clear the queue. `current` becomes null, which also
  /// dismisses the mini-player pill.
  Future<void> stop() async {
    await _player.stop();
    state = const MusicPlayerState();
    _log.info('Stopped playback, queue cleared');
  }
  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> setShuffle(bool on) async {
    await _player.setShuffleModeEnabled(on);
  }

  Future<void> cycleRepeat() async {
    final next = switch (_player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _player.setLoopMode(next);
  }
}

final musicPlayerProvider =
    NotifierProvider<MusicPlayerController, MusicPlayerState>(
        MusicPlayerController.new);
