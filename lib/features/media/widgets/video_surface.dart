import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'media_transport_controls.dart';

/// THE video rendering surface: aspect-correct picture, buffering indicator,
/// and tap-to-toggle auto-hiding transport controls. Renders a controller it
/// does NOT own — [PlaybackController] owns every video controller (that's
/// where PiP will attach). Used by the fullscreen playback page and the media
/// viewer's video pages alike, so controls behave identically everywhere.
class VideoSurface extends StatefulWidget {
  const VideoSurface({super.key, required this.controller, this.title});

  final VideoPlayerController controller;

  /// Announced to screen readers for the video region.
  final String? title;

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface> {
  bool _controlsVisible = true;
  Timer? _hideTimer;

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && widget.controller.value.isPlaying) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggle() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
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
    final c = widget.controller;
    return Semantics(
      label: widget.title == null ? 'Video player' : 'Video: ${widget.title}',
      // The tap target toggles controls — tell assistive tech what it does.
      onTapHint: 'show or hide playback controls',
      child: GestureDetector(
        onTap: _toggle,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio:
                    c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: c,
              builder: (context, value, _) => value.isBuffering
                  ? const CircularProgressIndicator()
                  : const SizedBox.shrink(),
            ),
            AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                // Hidden controls must not swallow taps or confuse a11y focus.
                ignoring: !_controlsVisible,
                child: ExcludeSemantics(
                  excluding: !_controlsVisible,
                  child: Align(
                    alignment: Alignment.bottomCenter,
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
                      padding: const EdgeInsets.only(top: 24),
                      child: MediaTransportControls(controller: c),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
