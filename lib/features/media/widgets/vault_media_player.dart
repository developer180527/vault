import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../core/logging/vault_log.dart';
import '../../../core/platform/media_codec.dart';
import '../../../core/platform/platform_services.dart';
import '../data/playback_position.dart';
import '../data/player_registry.dart';
import 'media_transport_controls.dart';

final _log = VaultLog.tag('player');

/// The shared playback core for video and audio. Built on `video_player`
/// (system AVPlayer/ExoPlayer — no bundled native libs, so it sideloads
/// cleanly), it handles: source resolution (local file or URL), resume from the
/// last position, buffering state, tap-to-toggle controls, and the MediaCodec
/// direct-play decision (which becomes meaningful for server sources — local
/// files always direct-play through the system decoder).
class VaultMediaPlayer extends ConsumerStatefulWidget {
  const VaultMediaPlayer({
    super.key,
    required this.source,
    required this.mediaId,
    this.isAudio = false,
    this.title,
    this.autoPlay = true,
    this.active = true,
  });

  /// A local file path or an http(s) URL.
  final String source;
  final String mediaId;
  final bool isAudio;
  final String? title;
  final bool autoPlay;

  /// False when this page is no longer the visible one (e.g. swiped away in the
  /// gallery); playback pauses so background audio doesn't continue.
  final bool active;

  @override
  ConsumerState<VaultMediaPlayer> createState() => _VaultMediaPlayerState();
}

class _VaultMediaPlayerState extends ConsumerState<VaultMediaPlayer> {
  VideoPlayerController? _controller;
  int? _instance;
  bool _initialized = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  Object? _error;
  late final AppLifecycleListener _lifecycle;
  // Captured up-front: `ref` MUST NOT be used in dispose() — doing so throws and
  // aborts teardown, leaving the controller (and its audio) alive.
  late final PlaybackPositionStore _positionStore;

  @override
  void initState() {
    super.initState();
    _positionStore = ref.read(playbackPositionStoreProvider);
    _log.debug('initState', fields: {'media': widget.mediaId});
    // Pause when the app leaves the foreground so audio never plays in the
    // background.
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _controller?.pause();
      },
    );
    _init();
  }

  @override
  void didUpdateWidget(VaultMediaPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Swiped away → pause so audio doesn't keep playing behind another page.
    if (oldWidget.active && !widget.active) {
      _controller?.pause();
    }
  }

  Future<void> _init() async {
    final controller = widget.source.startsWith('http')
        ? VideoPlayerController.networkUrl(Uri.parse(widget.source))
        : VideoPlayerController.file(File(widget.source));
    // Assign immediately so dispose() can always tear this down — even if the
    // viewer is closed while we're still awaiting initialize()/play(). Without
    // this the controller orphans and its audio keeps playing.
    _controller = controller;
    _instance = PlayerRegistry.open(widget.mediaId);
    try {
      unawaited(_decidePlayback());
      final sw = Stopwatch()..start();
      await controller.initialize();
      _log.debug('initialized', fields: {
        'media': widget.mediaId,
        'instance': _instance,
        'ms': sw.elapsedMilliseconds,
      });
      if (!mounted) return; // dispose() owns teardown from here

      final resume = await _positionStore.get(widget.mediaId);
      if (resume != null && resume < controller.value.duration) {
        await controller.seekTo(resume);
        _log.debug('Resumed playback',
            fields: {'id': widget.mediaId, 'at': resume.inSeconds});
      }
      if (mounted && widget.active && widget.autoPlay) {
        await controller.play();
      }
      if (mounted) {
        setState(() => _initialized = true);
        _scheduleHide();
      }
    } catch (e, s) {
      _log.error('Playback init failed',
          fields: {'source': widget.source}, error: e, stackTrace: s);
      if (mounted) setState(() => _error = e);
    }
  }

  /// Wires the device codec support into the direct-play-vs-transcode decision.
  /// Local files have unknown codecs → direct play; a future server source will
  /// carry real track info and a `NeedsTranscode` result would swap in an HLS
  /// URL from the server.
  Future<void> _decidePlayback() async {
    final support = await ref.read(mediaSupportProvider.future);
    final ext = widget.source.split('.').last.toLowerCase();
    final plan = planPlayback(MediaTrack(container: ext), support);
    _log.info('Playback plan', fields: {
      'id': widget.mediaId,
      'plan': plan is DirectPlay ? 'direct' : 'transcode',
      'hwDecode': support.hardwareDecode,
    });
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  @override
  void dispose() {
    final controller = _controller;
    final id = widget.mediaId;
    final instance = _instance;
    _log.debug('dispose() ENTERED', fields: {
      'media': id,
      'instance': instance,
      'hasController': controller != null,
      'isPlaying': controller?.value.isPlaying,
    });
    _lifecycle.dispose();
    _hideTimer?.cancel();
    _controller = null;
    if (controller != null) {
      if (controller.value.isInitialized) {
        // Use the captured store, NOT ref (which throws in dispose).
        _positionStore.save(
          id,
          controller.value.position,
          controller.value.duration,
        );
      }
      _teardown(controller, id, instance);
    }
    super.dispose();
  }

  /// Fully stop and release a controller. On iOS `dispose()` alone can leave
  /// audio playing, so we silence and pause first. Runs async (fire-and-forget)
  /// since the widget is already going away. Every step is logged so the exact
  /// failure point (if any) is measurable.
  static Future<void> _teardown(
      VideoPlayerController controller, String id, int? instance) async {
    try {
      await controller.setVolume(0);
      _log.debug('teardown: volume 0', fields: {'instance': instance});
      await controller.pause();
      _log.debug('teardown: paused', fields: {'instance': instance});
    } catch (e) {
      _log.warn('teardown pause/volume failed',
          fields: {'instance': instance}, error: e);
    }
    try {
      await controller.dispose();
      _log.debug('teardown: disposed', fields: {'instance': instance});
    } catch (e) {
      _log.error('teardown dispose failed',
          fields: {'instance': instance}, error: e);
    }
    if (instance != null) PlayerRegistry.close(instance, id);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Center(
        child: Text('Could not play this item',
            style: TextStyle(color: Colors.white70)),
      );
    }
    final controller = _controller;
    if (controller == null || !_initialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return GestureDetector(
      onTap: _toggleControls,
      child: Stack(
        alignment: Alignment.center,
        children: [
          widget.isAudio
              ? _AudioSurface(title: widget.title)
              : Center(
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: VideoPlayer(controller),
                  ),
                ),
          ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, value, _) => value.isBuffering
                ? const CircularProgressIndicator()
                : const SizedBox.shrink(),
          ),
          AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
                  ),
                ),
                padding: const EdgeInsets.only(top: 24),
                child: MediaTransportControls(controller: controller),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder surface for audio-only playback (a real album-art/now-playing
/// UI lands with server music; local media has no audio source yet).
class _AudioSurface extends StatelessWidget {
  const _AudioSurface({this.title});

  final String? title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.music_note, size: 96, color: Colors.white24),
          if (title != null) ...[
            const SizedBox(height: 16),
            Text(title!, style: const TextStyle(color: Colors.white70)),
          ],
        ],
      ),
    );
  }
}
