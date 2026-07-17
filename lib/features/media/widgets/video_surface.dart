import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'media_transport_controls.dart';

/// THE video rendering surface: aspect-correct picture + buffering indicator.
/// Renders a controller it does NOT own — [PlaybackController] owns every
/// video controller (that's where PiP will attach).
///
/// [showControls] draws the [VideoControls] overlay on top. The fullscreen
/// playback page uses that. The media viewer sets it false and floats its own
/// [VideoControls] at the Scaffold level instead — because inside
/// PhotoViewGallery this surface is sized to the video's letterbox box, so an
/// overlay here would collapse onto the picture. Controls must live above the
/// gallery to span the whole screen.
class VideoSurface extends StatelessWidget {
  const VideoSurface({
    super.key,
    required this.controller,
    this.title,
    this.showControls = true,
  });

  final VideoPlayerController controller;

  /// Announced to screen readers for the video region.
  final String? title;

  final bool showControls;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio == 0
                ? 16 / 9
                : controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
        ),
        if (showControls)
          Positioned.fill(
            child: VideoControls(controller: controller, title: title),
          ),
        // Above the controls so a stall is visible even mid-interaction.
        ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, value, _) => value.isBuffering
              ? const CircularProgressIndicator()
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Tap-to-toggle, auto-hiding transport chrome for a video: a scrim, the
/// thumb-reachable center cluster (skip ±10 / play), and the bottom scrubber.
/// Fills its parent — place it in a [Positioned.fill] (or as [VideoSurface]'s
/// own overlay) so it spans the full area, never the video's letterbox strip.
class VideoControls extends StatefulWidget {
  const VideoControls({super.key, required this.controller, this.title});

  final VideoPlayerController controller;
  final String? title;

  @override
  State<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<VideoControls> {
  bool _visible = true;
  Timer? _hideTimer;

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && widget.controller.value.isPlaying) {
        setState(() => _visible = false);
      }
    });
  }

  void _toggle() {
    setState(() => _visible = !_visible);
    if (_visible) _scheduleHide();
  }

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.title == null ? 'Video player' : 'Video: ${widget.title}',
      onTapHint: 'show or hide playback controls',
      // Opaque + always-active tap so a tap anywhere on the surface toggles
      // the chrome, even while it's hidden. Horizontal drags aren't claimed
      // here, so page-swiping still reaches the gallery below.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !_visible,
            child: ExcludeSemantics(
              excluding: !_visible,
              // All children explicitly Positioned: they lay out against the
              // Stack's final size unconditionally, so the scrubber can NEVER
              // collapse onto the center cluster regardless of the constraint
              // path this overlay is mounted under (the squished-controls bug).
              child: Stack(
                children: [
                  // Soft scrim so white controls stay legible on bright
                  // footage.
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.35),
                    ),
                  ),
                  // Center cluster: on phones thumbs land mid-screen, so the
                  // primary transport lives there.
                  Positioned.fill(
                    child: Center(
                      child: _CenterControls(
                        controller: widget.controller,
                        onInteract: _scheduleHide,
                      ),
                    ),
                  ),
                  // Scrubber pinned to the bottom edge, clear of the home
                  // indicator on phones.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.6),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      padding: EdgeInsets.only(
                        top: 24,
                        bottom: MediaQuery.paddingOf(context).bottom,
                      ),
                      child: MediaTransportControls(
                        controller: widget.controller,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The thumb-reachable transport cluster: skip back 10s, play/pause, skip
/// forward 10s. Any press restarts the auto-hide countdown via [onInteract].
class _CenterControls extends StatelessWidget {
  const _CenterControls({required this.controller, required this.onInteract});

  final VideoPlayerController controller;
  final VoidCallback onInteract;

  void _skip(Duration by) {
    final v = controller.value;
    var target = v.position + by;
    if (target < Duration.zero) target = Duration.zero;
    if (target > v.duration) target = v.duration;
    controller.seekTo(target);
    onInteract();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            iconSize: 36,
            color: Colors.white,
            tooltip: 'Back 10 seconds',
            icon: const Icon(Icons.replay_10),
            onPressed: () => _skip(const Duration(seconds: -10)),
          ),
          const SizedBox(width: 24),
          IconButton(
            iconSize: 64,
            color: Colors.white,
            tooltip: value.isPlaying ? 'Pause' : 'Play',
            icon: Icon(
              value.isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_fill,
            ),
            onPressed: () {
              value.isPlaying ? controller.pause() : controller.play();
              onInteract();
            },
          ),
          const SizedBox(width: 24),
          IconButton(
            iconSize: 36,
            color: Colors.white,
            tooltip: 'Forward 10 seconds',
            icon: const Icon(Icons.forward_10),
            onPressed: () => _skip(const Duration(seconds: 10)),
          ),
        ],
      ),
    );
  }
}
