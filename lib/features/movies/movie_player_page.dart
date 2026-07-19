import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/client/vault_client.dart';
import '../../core/logging/vault_log.dart';
import '../../core/models/server_movie.dart';
import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import '../media/widgets/video_surface.dart';

final _log = VaultLog.tag('movieplayer');

/// Opens the movie player fullscreen (landscape-locked while open).
Future<void> openMoviePlayer(BuildContext context, ServerMovie movie) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => MoviePlayerPage(movie: movie)),
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

  /// (Re)open the video for the given audio track. Default track uses a plain
  /// signed URL (client-side seek works); a non-default track goes through the
  /// remux endpoint with a server start offset.
  Future<VideoPlayerController> _open(int audio, {int startSec = 0}) async {
    final uri = audio > 0
        ? _api.streamUri(movie.id, audio: audio, startSec: startSec)
        : (movie.streamUrl != null
              ? _api.resolveStreamUrl(movie.streamUrl!)
              : _api.streamUri(movie.id));
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
    // Default track supports real seeking → resume client-side. (Non-default
    // is a remux pipe; the server already started at [startSec].)
    if (audio == 0 && startSec > 0) {
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
            return _ErrorView(onBack: () => Navigator.of(context).maybePop());
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
              // The video + tap-to-toggle transport chrome.
              VideoSurface(controller: c, title: movie.title),
              // Subtitle overlay, lifted above the scrubber.
              Positioned(
                left: 0,
                right: 0,
                bottom: 72,
                child: _SubtitleOverlay(controller: c),
              ),
              // Top bar: back + audio/subtitle pickers.
              SafeArea(
                child: _TopBar(
                  movie: movie,
                  audio: _audio,
                  subKey: _subKey,
                  onBack: () => Navigator.of(context).maybePop(),
                  onAudio: _switchAudio,
                  onSubtitle: _switchSubtitle,
                ),
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

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.movie,
    required this.audio,
    required this.subKey,
    required this.onBack,
    required this.onAudio,
    required this.onSubtitle,
  });

  final ServerMovie movie;
  final int audio;
  final String? subKey;
  final VoidCallback onBack;
  final ValueChanged<int> onAudio;
  final ValueChanged<String?> onSubtitle;

  @override
  Widget build(BuildContext context) {
    final selectableAudio = movie.audio.length > 1;
    final selectableSubs = movie.subs.where((s) => s.text).toList();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.5), Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              movie.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          if (selectableAudio)
            _AudioMenu(movie: movie, current: audio, onSelect: onAudio),
          if (selectableSubs.isNotEmpty)
            _SubMenu(subs: selectableSubs, current: subKey, onSelect: onSubtitle),
        ],
      ),
    );
  }
}

class _AudioMenu extends StatelessWidget {
  const _AudioMenu({
    required this.movie,
    required this.current,
    required this.onSelect,
  });
  final ServerMovie movie;
  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Audio track',
      icon: const Icon(Icons.multitrack_audio, color: Colors.white),
      initialValue: current,
      onSelected: onSelect,
      itemBuilder: (context) => [
        for (final a in movie.audio)
          PopupMenuItem(
            value: a.index,
            child: Row(
              children: [
                Icon(Icons.check,
                    size: 16,
                    color: a.index == current
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent),
                const SizedBox(width: 8),
                Text(a.label),
              ],
            ),
          ),
      ],
    );
  }
}

class _SubMenu extends StatelessWidget {
  const _SubMenu({
    required this.subs,
    required this.current,
    required this.onSelect,
  });
  final List<MovieSub> subs;
  final String? current;
  final ValueChanged<String?> onSelect;

  /// The track key the server expects: `e<embedded idx>` or `x<sidecar idx>`.
  static String keyFor(List<MovieSub> subs, MovieSub s) {
    if (s.isExternal) {
      final externals = subs.where((x) => x.isExternal).toList();
      return 'x${externals.indexOf(s)}';
    }
    return 'e${s.index}';
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String?>(
      tooltip: 'Subtitles',
      icon: Icon(
        current == null ? Icons.subtitles_outlined : Icons.subtitles,
        color: Colors.white,
      ),
      onSelected: onSelect,
      itemBuilder: (context) => [
        PopupMenuItem<String?>(
          value: null,
          child: _row(context, 'Off', current == null),
        ),
        for (final s in subs)
          PopupMenuItem<String?>(
            value: keyFor(subs, s),
            child: _row(context, s.label, keyFor(subs, s) == current),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, String label, bool selected) => Row(
    children: [
      Icon(Icons.check,
          size: 16,
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent),
      const SizedBox(width: 8),
      Text(label),
    ],
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white54, size: 40),
          const SizedBox(height: 12),
          const Text('Playback failed',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          TextButton(onPressed: onBack, child: const Text('Go back')),
        ],
      ),
    );
  }
}
