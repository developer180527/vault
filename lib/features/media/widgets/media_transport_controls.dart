import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Shared transport bar used by both video and audio playback: play/pause, a
/// scrubber bound to the controller's position, and elapsed/total time. Rebuilds
/// off the controller's own [ValueListenable], so no polling.
class MediaTransportControls extends StatelessWidget {
  const MediaTransportControls({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final position = value.position;
        final total = value.duration;
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
                    value: _clamp(position, total),
                    max: total.inMilliseconds.toDouble().clamp(1, double.infinity),
                    onChanged: (v) => controller
                        .seekTo(Duration(milliseconds: v.round())),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_fmt(position)} / ${_fmt(total)}',
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

  double _clamp(Duration position, Duration total) {
    final p = position.inMilliseconds.toDouble();
    final t = total.inMilliseconds.toDouble();
    return t <= 0 ? 0 : p.clamp(0, t);
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
