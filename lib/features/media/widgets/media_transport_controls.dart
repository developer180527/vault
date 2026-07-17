import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// The video scrubber bar: a seek slider bound to the controller's position
/// with elapsed/total time. Play/pause lives in [VideoSurface]'s center
/// cluster (standard mobile video layout — thumbs reach the middle of the
/// screen, not the bottom corner). Rebuilds off the controller's own
/// [ValueListenable], so no polling.
///
/// While the user drags, the thumb follows the finger (local drag value)
/// instead of fighting the position updates — and continuous seeks during the
/// drag are avoided (one seek on release), which kept the decoder thrashing.
class MediaTransportControls extends StatefulWidget {
  const MediaTransportControls({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  State<MediaTransportControls> createState() => _MediaTransportControlsState();
}

class _MediaTransportControlsState extends State<MediaTransportControls> {
  VideoPlayerController get controller => widget.controller;

  /// Non-null while dragging or waiting for the seek to land.
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final position = value.position;
        final total = value.duration;
        final max =
            total.inMilliseconds.toDouble().clamp(1.0, double.infinity);

        // Release the held drag value once playback catches up to the seek.
        if (_dragMs != null &&
            (position.inMilliseconds - _dragMs!).abs() < 1000) {
          _dragMs = null;
        }
        final shown = (_dragMs ?? position.inMilliseconds.toDouble())
            .clamp(0.0, max);

        final shownLabel = _fmt(Duration(milliseconds: shown.round()));
        final totalLabel = _fmt(total);
        // SafeArea: on phones the bar must clear the home indicator / nav
        // gestures, or the scrubber is half-unreachable.
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Text(
                    shownLabel,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      // A generous overlay keeps the drag target finger-sized
                      // even though the visible track is slim.
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 18),
                    ),
                    child: Semantics(
                      label: 'Seek',
                      value: '$shownLabel of $totalLabel',
                      child: Slider(
                        value: shown,
                        max: max,
                        onChangeStart: (v) => setState(() => _dragMs = v),
                        onChanged: (v) => setState(() => _dragMs = v),
                        onChangeEnd: (v) {
                          controller
                              .seekTo(Duration(milliseconds: v.round()));
                          // _dragMs holds until position reflects the seek.
                        },
                      ),
                    ),
                  ),
                ),
                // The slider's semantics value already announces position;
                // the raw time text would just be noise.
                ExcludeSemantics(
                  child: Text(
                    totalLabel,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
