import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Shared transport bar used by both video and audio playback: play/pause, a
/// scrubber bound to the controller's position, and elapsed/total time.
/// Rebuilds off the controller's own [ValueListenable], so no polling.
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

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  iconSize: 36,
                  color: Colors.white,
                  icon: Icon(value.isPlaying
                      ? Icons.pause_circle
                      : Icons.play_circle),
                  onPressed: () =>
                      value.isPlaying ? controller.pause() : controller.play(),
                ),
                Expanded(
                  child: Slider(
                    value: shown,
                    max: max,
                    onChangeStart: (v) => setState(() => _dragMs = v),
                    onChanged: (v) => setState(() => _dragMs = v),
                    onChangeEnd: (v) {
                      controller.seekTo(Duration(milliseconds: v.round()));
                      // _dragMs holds until position reflects the seek.
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_fmt(Duration(milliseconds: shown.round()))} / ${_fmt(total)}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ],
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
