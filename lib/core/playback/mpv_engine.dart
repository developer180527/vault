import 'dart:async';

// media_kit exports its own `Playable`; hide it so ours (the app-wide
// playback seam) is the only one in scope here.
import 'package:media_kit/media_kit.dart' hide Playable;
import 'package:media_kit_video/media_kit_video.dart';

import '../logging/vault_log.dart';
import 'playable.dart';

final _log = VaultLog.tag('mpv');

/// The libmpv-backed video engine (media_kit), evaluated as a replacement for
/// video_player (AVPlayer/ExoPlayer).
///
/// Why it matters here: AVPlayer can't open Matroska at all and neither engine
/// exposes embedded-track selection through `video_player`, which is why every
/// audio switch today costs a server remux and a stream restart. libmpv
/// demuxes MKV natively and switches tracks **in-player**, so:
///
///   * the server goes back to plain `ServeFile` + Range for every case —
///     no ffmpeg, no CPU, perfect seeking on every track;
///   * switching is instant and local, with no rebuffer;
///   * embedded ASS/PGS subtitles become renderable (the image-based subs we
///     currently have to hide because they'd need OCR).
///
/// Kept behind this wrapper rather than used directly so the rest of the app
/// never imports media_kit — if libmpv disappoints on a platform, only this
/// file and its page change.
class MpvEngine {
  MpvEngine() {
    _player = Player();
    _controller = VideoController(_player);
    _subs.addAll([
      _player.stream.tracks.listen((_) => _emit()),
      _player.stream.track.listen((_) => _emit()),
      _player.stream.playing.listen((_) => _emit()),
      _player.stream.completed.listen((_) => _emit()),
      _player.stream.buffering.listen((_) => _emit()),
      _player.stream.duration.listen((_) => _emit()),
      _player.stream.error.listen((e) {
        _lastError = e;
        _log.warn('mpv error', fields: {'err': e});
        _emit();
      }),
    ]);
  }

  late final Player _player;
  late final VideoController _controller;
  final List<StreamSubscription<Object?>> _subs = [];
  final _stateController = StreamController<MpvState>.broadcast();
  String? _lastError;

  /// The widget surface. Callers render `Video(controller: engine.controller)`.
  VideoController get controller => _controller;
  Player get player => _player;

  /// Coarse state changes (tracks, playing, duration) for UI rebuilds.
  /// Position is deliberately NOT here — it ticks constantly; consume
  /// [positionStream] separately so the whole chrome doesn't rebuild 60×/s.
  Stream<MpvState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _player.stream.position;

  MpvState get state => _snapshot();

  void _emit() {
    if (!_stateController.isClosed) _stateController.add(_snapshot());
  }

  MpvState _snapshot() => MpvState(
    playing: _player.state.playing,
    completed: _player.state.completed,
    buffering: _player.state.buffering,
    duration: _player.state.duration,
    audioTracks: [
      for (final t in _player.state.tracks.audio)
        // "auto"/"no" are mpv's pseudo-tracks, not real streams.
        if (t.id != 'auto' && t.id != 'no')
          MpvTrack(id: t.id, label: _label(t), language: t.language ?? ''),
    ],
    subtitleTracks: [
      for (final t in _player.state.tracks.subtitle)
        if (t.id != 'auto' && t.id != 'no')
          MpvTrack(id: t.id, label: _label(t), language: t.language ?? ''),
    ],
    currentAudioId: _player.state.track.audio.id,
    currentSubtitleId: _player.state.track.subtitle.id,
    error: _lastError,
  );

  /// "English Dub" › "eng" › "Track 2" — a picker row is never blank.
  static String _label(dynamic t) {
    final title = (t.title as String?) ?? '';
    if (title.isNotEmpty) return title;
    final lang = (t.language as String?) ?? '';
    if (lang.isNotEmpty) return lang.toUpperCase();
    return 'Track ${t.id}';
  }

  /// Open a source. Network sources carry the bearer via mpv's HTTP headers,
  /// so a signed URL and a bearer-gated one both work.
  Future<void> open(Playable item, {bool autoPlay = true, Duration? startAt}) async {
    _lastError = null;
    await _player.open(
      Media(
        item.uri.toString(),
        httpHeaders: item.headers.isEmpty ? null : item.headers,
        start: startAt,
      ),
      play: autoPlay,
    );
    _log.info('mpv opened', fields: {'title': item.title});
  }

  Future<void> playPause() =>
      _player.state.playing ? _player.pause() : _player.play();
  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> seek(Duration to) => _player.seek(to);
  Future<void> setVolume(double v) => _player.setVolume(v * 100);

  /// Switch audio track IN-PLAYER — no server round trip, no rebuffer of the
  /// video, no restart. This is the whole point of the engine swap.
  Future<void> setAudioTrack(String id) async {
    await _player.setAudioTrack(AudioTrack(id, null, null));
    _log.info('mpv audio track set', fields: {'id': id});
  }

  /// Switch (or disable, with id 'no') the subtitle track — including
  /// embedded ASS/PGS, which libmpv renders itself.
  Future<void> setSubtitleTrack(String id) async {
    await _player.setSubtitleTrack(SubtitleTrack(id, null, null));
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _stateController.close();
    await _player.dispose();
  }
}

/// One selectable track reported by libmpv.
class MpvTrack {
  const MpvTrack({required this.id, required this.label, this.language = ''});
  final String id;
  final String label;
  final String language;
}

/// A snapshot of engine state for the UI.
class MpvState {
  const MpvState({
    this.playing = false,
    this.completed = false,
    this.buffering = false,
    this.duration = Duration.zero,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.currentAudioId = '',
    this.currentSubtitleId = '',
    this.error,
  });

  final bool playing;
  final bool completed;
  final bool buffering;
  final Duration duration;
  final List<MpvTrack> audioTracks;
  final List<MpvTrack> subtitleTracks;
  final String currentAudioId;
  final String currentSubtitleId;
  final String? error;

  bool get canSwitchAudio => audioTracks.length > 1;
  bool get hasSubtitles => subtitleTracks.isNotEmpty;
}
