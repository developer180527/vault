import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/client/vault_client.dart';
import '../../core/models/server_movie.dart';
import '../../core/playback/mpv_engine.dart';
import '../../core/playback/playable.dart';
import '../media/widgets/video_surface.dart';
import '../media/widgets/video_transport.dart';
import 'widgets/movie_top_bar.dart';

/// The movie player on the libmpv engine.
///
/// Deliberately indistinguishable from [MoviePlayerPage]: same [VideoSurface]
/// chrome, same [MovieTopBar], same auto-hide, same keyboard transport. Only
/// the decoder differs — and the differences that leak through are all
/// improvements:
///
///   * MKV/HEVC/AC-3 open natively — no server ffmpeg, no CPU, no pipe.
///   * Audio switches happen IN-PLAYER: instant, no rebuffer, no restart.
///   * Seeking works on every track (ordinary HTTP Range on the original
///     file), instead of costing a server-side re-seek.
///   * Embedded ASS/PGS subtitles render, which the native path can't do.
class MpvMoviePlayerPage extends ConsumerStatefulWidget {
  const MpvMoviePlayerPage({super.key, required this.movie});

  final ServerMovie movie;

  @override
  ConsumerState<MpvMoviePlayerPage> createState() =>
      _MpvMoviePlayerPageState();
}

class _MpvMoviePlayerPageState extends ConsumerState<MpvMoviePlayerPage> {
  late final MoviesApi _api = ref.read(vaultClientProvider).movies;
  late final MpvEngine _engine = MpvEngine();
  late final MpvTransport _transport = MpvTransport(_engine);

  MpvState _state = const MpvState();
  StreamSubscription<MpvState>? _stateSub;
  Timer? _progressTimer;

  /// Ordinal of the selected audio track (matches the server's descriptor).
  int _audio = 0;

  /// Selected subtitle key ("e0"/"x1"), or null for off.
  String? _subKey;

  bool _opening = true;
  Object? _error;

  ServerMovie get movie => widget.movie;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _stateSub = _engine.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    unawaited(_open());
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _reportProgress();
    unawaited(_stateSub?.cancel());
    _transport.dispose();
    unawaited(_engine.dispose());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final headers = await _api.authHeaders();
      // The RAW file, default track — libmpv demuxes the container itself, so
      // there is no ?remux= / ?audio= and the server just serves bytes.
      await _engine.open(
        Playable(
          id: movie.id,
          kind: PlayableKind.video,
          uri: _api.streamUri(movie.id),
          title: movie.title,
          headers: headers,
        ),
        startAt: movie.resumeMs > 0
            ? Duration(milliseconds: movie.resumeMs)
            : null,
      );
      _startProgressTimer();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer =
        Timer.periodic(const Duration(seconds: 20), (_) => _reportProgress());
  }

  void _reportProgress() {
    final pos = _transport.position.inMilliseconds;
    final dur = _transport.duration.inMilliseconds;
    if (pos <= 0) return;
    unawaited(_api.reportWatch(movie.id, positionMs: pos, durationMs: dur));
  }

  /// In-player switch — no stream restart, so position is preserved for free.
  Future<void> _switchAudio(int ordinal) async {
    if (ordinal == _audio) return;
    setState(() => _audio = ordinal);
    await _engine.setAudioTrackAt(ordinal);
  }

  /// Embedded subtitles switch in-player too. Sidecar tracks ("x…") aren't in
  /// the container, so they're fetched from the server as before.
  Future<void> _switchSubtitle(String? key) async {
    setState(() => _subKey = key);
    if (key == null) {
      await _engine.setSubtitleTrackAt(null);
      return;
    }
    if (key.startsWith('e')) {
      final ordinal = int.tryParse(key.substring(1));
      // The descriptor's embedded index is the container ordinal mpv used.
      await _engine.setSubtitleTrackAt(ordinal);
    } else {
      // Sidecar: fetch the WebVTT with our bearer, hand mpv the text.
      await _engine.setSubtitleData(await _api.subtitleVtt(movie.id, key));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Builder(
        builder: (context) {
          if (_error != null || _state.error != null) {
            return PlayerErrorView(
              onBack: () => Navigator.of(context).maybePop(),
              detail: '${_error ?? _state.error}',
            );
          }
          if (_opening) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          return VideoSurface.mpv(
            transport: _transport,
            picture: _engine.videoWidget(),
            title: movie.title,
            topOverlay: MovieTopBar(
              movie: movie,
              audio: _audio,
              subKey: _subKey,
              onBack: () => Navigator.of(context).maybePop(),
              onAudio: _switchAudio,
              onSubtitle: _switchSubtitle,
            ),
          );
        },
      ),
    );
  }
}
