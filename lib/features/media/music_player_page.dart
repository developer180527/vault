import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import 'data/music_player_controller.dart';

/// Full-screen now-playing screen, styled after Apple Music: large artwork,
/// track title, scrubber, and transport controls. Reads the global music
/// controller so it reflects (and drives) playback started from the list.
class MusicPlayerPage extends ConsumerWidget {
  const MusicPlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(musicPlayerProvider);
    final controller = ref.read(musicPlayerProvider.notifier);
    final player = controller.player;
    final track = state.current;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              scheme.primaryContainer,
              scheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
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
                        await controller.stop();
                        if (context.mounted) {
                          Navigator.of(context).maybePop();
                        }
                      },
                    ),
                  ],
                ),
                const Spacer(),
                _Artwork(scheme: scheme),
                const SizedBox(height: 40),
                Text(
                  track?.title ?? 'Nothing playing',
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text('Local music',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 24),
                _Scrubber(player: player),
                const SizedBox(height: 8),
                _Controls(controller: controller, player: player),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final side = MediaQuery.sizeOf(context).width.clamp(200.0, 360.0) - 56;
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
      child: Icon(Icons.music_note, size: side * 0.4, color: scheme.primary),
    );
  }
}

/// Position scrubber bound to the player's streams.
class _Scrubber extends StatelessWidget {
  const _Scrubber({required this.player});
  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final total = player.duration ?? Duration.zero;
        final max = total.inMilliseconds.toDouble();
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: position.inMilliseconds
                    .clamp(0, max <= 0 ? 1 : max.toInt())
                    .toDouble(),
                max: max <= 0 ? 1 : max,
                onChanged: (v) =>
                    player.seek(Duration(milliseconds: v.round())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(position),
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
  final MusicPlayerController controller;
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
