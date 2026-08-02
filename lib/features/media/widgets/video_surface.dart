import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/playback/playable.dart';
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
    this.topOverlay,
    this.audioTracks = const [],
    this.currentAudioTrack = 0,
    this.onSelectAudio,
  });

  final VideoPlayerController controller;

  /// Announced to screen readers for the video region.
  final String? title;

  final bool showControls;

  /// Optional chrome pinned to the TOP (e.g. a back bar with track/subtitle
  /// pickers). Rendered inside [VideoControls] so it fades and toggles with the
  /// rest of the chrome under ONE tap-catcher — never a separate always-on
  /// layer that swallows the tap-to-show-again.
  final Widget? topOverlay;

  /// Audio tracks the source declares (see [Playable.audioTracks]). Passed
  /// straight through to [VideoControls], which renders the picker.
  final List<AudioTrackOption> audioTracks;
  final int currentAudioTrack;
  final ValueChanged<int>? onSelectAudio;

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
            child: VideoControls(
              controller: controller,
              title: title,
              topOverlay: topOverlay,
              audioTracks: audioTracks,
              currentAudioTrack: currentAudioTrack,
              onSelectAudio: onSelectAudio,
            ),
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
  const VideoControls({
    super.key,
    required this.controller,
    this.title,
    this.topOverlay,
    this.audioTracks = const [],
    this.currentAudioTrack = 0,
    this.onSelectAudio,
  });

  final VideoPlayerController controller;
  final String? title;

  /// Top chrome that fades/toggles with the controls (see [VideoSurface]).
  final Widget? topOverlay;

  /// Selectable audio tracks; fewer than two hides the control.
  final List<AudioTrackOption> audioTracks;
  final int currentAudioTrack;
  final ValueChanged<int>? onSelectAudio;

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

  /// Reveal the chrome (used by keyboard shortcuts, which should surface the
  /// controls so the user sees what their keypress did).
  void _reveal() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _playPause() {
    final v = widget.controller.value;
    v.isPlaying ? widget.controller.pause() : widget.controller.play();
    _reveal();
  }

  void _seekBy(Duration by) {
    final v = widget.controller.value;
    var target = v.position + by;
    if (target < Duration.zero) target = Duration.zero;
    if (target > v.duration) target = v.duration;
    widget.controller.seekTo(target);
    _reveal();
  }

  /// Desktop/keyboard transport: space or K toggles play, arrows seek ±10s
  /// (±60s with shift), J/L match the common player convention. Handled on
  /// key DOWN only so a held key doesn't machine-gun.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final step = Duration(seconds: shift ? 60 : 10);
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      _playPause();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyJ) {
      _seekBy(-step);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyL) {
      _seekBy(step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
    return Focus(
      // autofocus so a desktop window's keyboard reaches the player the moment
      // it opens — space/arrows are the transport people reach for first.
      autofocus: true,
      onKeyEvent: _onKey,
      child: Semantics(
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
                    // The audio-track picker, when the source declares more
                    // than one. Lives HERE rather than in a specific page so
                    // every video surface — catalog movies, a Files video,
                    // anything later — gets it from the same code.
                    if (widget.audioTracks.length > 1)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: SafeArea(
                          bottom: false,
                          child: _AudioTrackButton(
                            tracks: widget.audioTracks,
                            current: widget.currentAudioTrack,
                            onSelect: widget.onSelectAudio,
                            onInteract: _scheduleHide,
                          ),
                        ),
                      ),
                    // Top chrome (back bar / pickers), fading with everything
                    // else. SafeArea keeps it clear of the notch.
                    if (widget.topOverlay != null)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: SafeArea(
                          bottom: false,
                          child: widget.topOverlay!,
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
      ),
    );
  }
}

/// The audio-language control. Switching costs a stream swap (the engines
/// can't select an embedded track), so the menu says which one is playing and
/// the swap carries the position across.
class _AudioTrackButton extends StatelessWidget {
  const _AudioTrackButton({
    required this.tracks,
    required this.current,
    required this.onSelect,
    required this.onInteract,
  });

  final List<AudioTrackOption> tracks;
  final int current;
  final ValueChanged<int>? onSelect;
  final VoidCallback onInteract;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Audio language',
      icon: const Icon(Icons.multitrack_audio, color: Colors.white),
      initialValue: current,
      onOpened: onInteract,
      onSelected: (i) {
        onInteract();
        onSelect?.call(i);
      },
      itemBuilder: (context) => [
        for (final t in tracks)
          PopupMenuItem<int>(
            value: t.index,
            child: Row(
              children: [
                Icon(
                  Icons.check,
                  size: 16,
                  color: t.index == current
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                ),
                const SizedBox(width: 8),
                Text(t.label),
              ],
            ),
          ),
      ],
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
