import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/platform/platform_info.dart';
import '../../core/playback/playback_controller.dart';
import 'data/dominant_color.dart';

/// Full-screen now-playing screen, styled after Apple Music: large artwork,
/// track title/artist, scrubber, transport controls, and a volume/output row.
/// Reads the centralized [PlaybackController], so it shows whatever audio is
/// playing — local music today, server music later — with no change here.
/// The background gradient is tinted from the artwork's dominant color.
class MusicPlayerPage extends ConsumerWidget {
  const MusicPlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(playbackProvider.notifier);
    final player = controller.player;
    final track = ref.watch(playbackProvider).currentAudio;
    final scheme = Theme.of(context).colorScheme;

    final artColor = track?.artwork == null
        ? null
        : ref.watch(artColorProvider(track!.id)).asData?.value;

    return Scaffold(
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              // Art-tinted when available; theme container otherwise. Blend
              // toward surface so text/controls stay readable on loud covers.
              artColor == null
                  ? scheme.primaryContainer
                  : Color.lerp(artColor, scheme.surface, 0.25)!,
              scheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 20),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    // Stop entirely: kills playback, clears the queue, and
                    // (via current == null) removes the mini-player pill.
                    IconButton(
                      tooltip: 'Stop',
                      icon: const Icon(Icons.stop_circle_outlined, size: 30),
                      onPressed: () async {
                        await controller.stopAudio();
                        if (context.mounted) {
                          Navigator.of(context).maybePop();
                        }
                      },
                    ),
                  ],
                ),
                const Spacer(),
                _Artwork(
                  art: track?.artwork,
                  artUri: track?.artworkUri,
                  headers: track?.headers ?? const {},
                ),
                const SizedBox(height: 32),
                Text(
                  track?.title ?? 'Nothing playing',
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                    (track?.subtitle.isEmpty ?? true)
                        ? 'Local music'
                        : track!.subtitle,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 20),
                _Scrubber(player: player),
                const SizedBox(height: 4),
                _Controls(controller: controller, player: player),
                const Spacer(),
                _VolumeRow(player: player),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({this.art, this.artUri, this.headers = const {}});

  /// Embedded bytes (local files) or a bearer-fetched URL (server streams).
  final Uint8List? art;
  final Uri? artUri;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final side = MediaQuery.sizeOf(context).width.clamp(200.0, 360.0) - 56;
    final fallback =
        Icon(Icons.music_note, size: side * 0.4, color: scheme.primary);
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 40,
              offset: const Offset(0, 20)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: art != null
          ? Image.memory(art!, fit: BoxFit.cover, gaplessPlayback: true)
          : artUri != null
              ? Image.network(
                  artUri.toString(),
                  headers: headers.isEmpty ? null : headers,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => fallback,
                )
              : fallback,
    );
  }
}

/// Position scrubber. While dragging, the thumb follows the finger (a local
/// drag value) instead of snapping back to the last stream tick — and stays
/// put after release until playback catches up to the seek target.
class _Scrubber extends StatefulWidget {
  const _Scrubber({required this.player});
  final AudioPlayer player;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  AudioPlayer get player => widget.player;

  /// Throttled position stream, created once. The default positionStream
  /// emits up to every 16ms — rebuilding the slider ~60×/s for the whole
  /// playback session. 200ms is indistinguishable on a scrubber and cuts
  /// that work by >90%.
  late final Stream<Duration> _position = player.createPositionStream(
    minPeriod: const Duration(milliseconds: 200),
    maxPeriod: const Duration(milliseconds: 500),
  );

  /// Non-null while dragging or waiting for the seek to land.
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: _position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final total = player.duration ?? Duration.zero;
        final max = total.inMilliseconds.toDouble().clamp(1.0, double.infinity);

        // Release the held drag value once playback has caught up with the
        // seek target (or drifted past it).
        if (_dragMs != null &&
            (position.inMilliseconds - _dragMs!).abs() < 1000) {
          _dragMs = null;
        }
        final shown =
            (_dragMs ?? position.inMilliseconds.toDouble()).clamp(0.0, max);

        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: shown,
                max: max,
                onChangeStart: (v) => setState(() => _dragMs = v),
                onChanged: (v) => setState(() => _dragMs = v),
                onChangeEnd: (v) {
                  player.seek(Duration(milliseconds: v.round()));
                  // Keep _dragMs until the stream reflects the new position.
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(Duration(milliseconds: shown.round())),
                      style: Theme.of(context).textTheme.bodySmall),
                  Text(_fmt(total),
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
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

class _Controls extends StatelessWidget {
  const _Controls({required this.controller, required this.player});
  final PlaybackController controller;
  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        StreamBuilder<bool>(
          stream: player.shuffleModeEnabledStream,
          builder: (context, snap) => IconButton(
            icon: const Icon(Icons.shuffle),
            color: (snap.data ?? false)
                ? Theme.of(context).colorScheme.primary
                : null,
            onPressed: () => controller.setShuffle(!(snap.data ?? false)),
          ),
        ),
        IconButton(
          iconSize: 40,
          icon: const Icon(Icons.skip_previous),
          onPressed: controller.previous,
        ),
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            return IconButton(
              iconSize: 72,
              icon: Icon(
                  playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
              color: Theme.of(context).colorScheme.primary,
              onPressed: controller.togglePlay,
            );
          },
        ),
        IconButton(
          iconSize: 40,
          icon: const Icon(Icons.skip_next),
          onPressed: controller.next,
        ),
        StreamBuilder<LoopMode>(
          stream: player.loopModeStream,
          builder: (context, snap) {
            final mode = snap.data ?? LoopMode.off;
            return IconButton(
              icon: Icon(
                  mode == LoopMode.one ? Icons.repeat_one : Icons.repeat),
              color: mode != LoopMode.off
                  ? Theme.of(context).colorScheme.primary
                  : null,
              onPressed: controller.cycleRepeat,
            );
          },
        ),
      ],
    );
  }
}

/// Volume slider plus (on iOS) the system audio-output picker for AirPlay /
/// Bluetooth routing.
class _VolumeRow extends StatelessWidget {
  const _VolumeRow({required this.player});
  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.volume_down, size: 20, color: scheme.onSurfaceVariant),
        Expanded(
          child: StreamBuilder<double>(
            stream: player.volumeStream,
            builder: (context, snap) {
              final volume = (snap.data ?? player.volume).clamp(0.0, 1.0);
              return SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5),
                ),
                child: Slider(
                  value: volume,
                  onChanged: player.setVolume,
                ),
              );
            },
          ),
        ),
        Icon(Icons.volume_up, size: 20, color: scheme.onSurfaceVariant),
        if (isIOS) ...[
          const SizedBox(width: 8),
          // System output picker (AirPlay/Bluetooth). Interactive platform
          // view: tapping presents the native route sheet.
          SizedBox(
            width: 40,
            height: 40,
            child: UiKitView(
              viewType: 'vault/route-picker',
              creationParams: {'tint': scheme.onSurfaceVariant.toARGB32()},
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),
        ],
      ],
    );
  }
}
