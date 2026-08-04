import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/client/vault_client.dart';
import '../../core/logging/vault_log.dart';
import '../../core/models/server_movie.dart';
import '../../core/platform/platform_services.dart';
import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import '../media/widgets/video_surface.dart';
import 'data/movie_playback.dart';
import 'mpv_movie_player_page.dart';
import 'widgets/movie_top_bar.dart';

final _log = VaultLog.tag('movieplayer');

/// Opens the movie player fullscreen (landscape-locked while open), on
/// whichever engine can actually play this title.
///
/// The choice is made HERE, once, rather than being a button the user has to
/// understand: a plain MP4 the device decodes natively keeps video_player
/// (hardware path, system PiP, lock-screen controls); anything else — MKV,
/// HEVC, AC-3, multi-track — goes to libmpv, which is the only engine that
/// opens it without server-side ffmpeg. Both pages wear identical chrome, so
/// this is invisible apart from things working.
Future<void> openMoviePlayer(
  BuildContext context,
  WidgetRef ref,
  ServerMovie movie,
) async {
  final support = await ref.read(mediaSupportProvider.future);
  if (!context.mounted) return;
  final engine = videoEngineFor(movie, support);
  _log.info('opening movie', fields: {
    'title': movie.title,
    'container': movie.container,
    'vcodec': movie.vcodec,
    'engine': engine.name,
  });
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => switch (engine) {
        VideoEngine.libmpv => MpvMoviePlayerPage(movie: movie),
        VideoEngine.native => MoviePlayerPage(movie: movie),
      },
    ),
  );
}

/// The movie player: central video session + resume, an audio-track selector
/// (server remux), and WebVTT subtitle overlay. Landscape-locked; reports
/// watch progress so Continue Watching stays truthful.
class MoviePlayerPage extends ConsumerStatefulWidget {
  const MoviePlayerPage({super.key, required this.movie});

  final ServerMovie movie;

  @override
  ConsumerState<MoviePlayerPage> createState() => _MoviePlayerPageState();
}

class _MoviePlayerPageState extends ConsumerState<MoviePlayerPage> {
  late final PlaybackController _playback = ref.read(playbackProvider.notifier);
  late final MoviesApi _api = ref.read(vaultClientProvider).movies;

  VideoPlayerController? _controller;
  Future<VideoPlayerController>? _future;

  /// Selected audio track index (0 = default; the direct-play path).
  int _audio = 0;

  /// Selected subtitle: null = off, else the track key ("e0" / "x1").
  String? _subKey;

  Timer? _progressTimer;

  ServerMovie get movie => widget.movie;

  @override
  void initState() {
    super.initState();
    // Fullscreen, landscape — a movie is a landscape experience.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _future = _open(_audio, startSec: movie.resumeMs ~/ 1000);
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _reportProgress();
    _playback.closeVideo(onlyIf: movie.id);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  /// (Re)open the video for the given audio track. The stream mode is chosen
  /// from this device's decoders + the file's codecs/container:
  ///   * direct    — original bytes, client-side seek (the signed URL path).
  ///   * remux     — decodable codecs in a non-native container (MKV→fMP4).
  ///   * transcode — a codec this device can't decode (HEVC/VP9/AV1, AC-3…).
  /// Remux/transcode are server-seeked pipes (no Range), so [startSec] is a
  /// server-side offset for them; only direct seeks client-side.
  Future<VideoPlayerController> _open(int audio, {int startSec = 0}) async {
    final support = await ref.read(mediaSupportProvider.future);
    final mode = movieStreamMode(movie, support, audioIndex: audio);
    final serverSeek = mode != MovieStreamMode.direct || audio > 0;

    final Uri uri;
    switch (mode) {
      case MovieStreamMode.transcode:
        uri = _api.streamUri(movie.id,
            audio: audio, startSec: startSec, transcode: true);
      case MovieStreamMode.remux:
        uri = _api.streamUri(movie.id,
            audio: audio, startSec: startSec, remux: true);
      case MovieStreamMode.direct:
        // Non-default audio still needs a remux even on a native container.
        uri = audio > 0
            ? _api.streamUri(movie.id, audio: audio, startSec: startSec)
            : (movie.streamUrl != null
                ? _api.resolveStreamUrl(movie.streamUrl!)
                : _api.streamUri(movie.id));
    }
    final headers = await _api.authHeaders();
    final c = await _playback.openVideo(
      Playable(
        id: movie.id,
        kind: PlayableKind.video,
        uri: uri,
        title: movie.title,
        headers: headers,
      ),
      autoPlay: true,
    );
    // Direct play supports real seeking → resume client-side. Remux/transcode
    // (and non-default audio) are server-seeked pipes: already at [startSec].
    if (!serverSeek && startSec > 0) {
      await c.seekTo(Duration(seconds: startSec));
    }
    if (_subKey != null) await _applySubtitle(c, _subKey!);
    _controller = c;
    _startProgressTimer();
    return c;
  }

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer =
        Timer.periodic(const Duration(seconds: 20), (_) => _reportProgress());
  }

  void _reportProgress() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final pos = c.value.position.inMilliseconds;
    final dur = c.value.duration.inMilliseconds;
    if (pos <= 0) return;
    unawaited(_api.reportWatch(movie.id, positionMs: pos, durationMs: dur));
  }

  Future<void> _applySubtitle(VideoPlayerController c, String track) async {
    try {
      final vtt = await _api.subtitleVtt(movie.id, track);
      await c.setClosedCaptionFile(Future.value(WebVTTCaptionFile(vtt)));
    } catch (e) {
      _log.warn('subtitle load failed', fields: {'track': track, 'err': '$e'});
    }
  }

  Future<void> _switchAudio(int audio) async {
    if (audio == _audio) return;
    final at = _controller?.value.position.inSeconds ?? 0;
    setState(() {
      _audio = audio;
      _future = _open(audio, startSec: at);
    });
  }

  Future<void> _switchSubtitle(String? key) async {
    setState(() => _subKey = key);
    final c = _controller;
    if (c == null) return;
    if (key == null) {
      await c.setClosedCaptionFile(null);
    } else {
      await _applySubtitle(c, key);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<VideoPlayerController>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return PlayerErrorView(
                onBack: () => Navigator.of(context).maybePop());
          }
          final c = snap.data;
          if (c == null) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              // The video + tap-to-toggle transport chrome. The top bar rides
              // INSIDE the controls (topOverlay) so it fades with them and a
              // tap anywhere reliably brings the whole chrome back — it used to
              // be a separate always-on layer.
              VideoSurface(
                controller: c,
                title: movie.title,
                topOverlay: MovieTopBar(
                  movie: movie,
                  audio: _audio,
                  subKey: _subKey,
                  onBack: () => Navigator.of(context).maybePop(),
                  onAudio: _switchAudio,
                  onSubtitle: _switchSubtitle,
                ),
              ),
              // Subtitle overlay, lifted above the scrubber — stays visible
              // even when the chrome is hidden.
              Positioned(
                left: 0,
                right: 0,
                bottom: 72,
                child: _SubtitleOverlay(controller: c),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Renders the current caption line over the video.
class _SubtitleOverlay extends StatelessWidget {
  const _SubtitleOverlay({required this.controller});
  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final text = value.caption.text;
        if (text.isEmpty) return const SizedBox.shrink();
        return Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                height: 1.3,
                shadows: [Shadow(blurRadius: 4, color: Colors.black)],
              ),
            ),
          ),
        );
      },
    );
  }
}
