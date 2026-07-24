import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/platform/design/glass_surface.dart';
import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import '../../features/media/data/server_music.dart' show artBytesProvider;
import '../../features/media/music_player_page.dart' show openMusicPlayer;

/// Apple-Music-style floating now-playing bar, docked at the BOTTOM of the
/// desktop window (native desktop only — tablets keep the sidebar strip). A
/// single glass pill: artwork + title/artist on the left, transport centred
/// over a live scrubber, volume + expand + stop on the right. Only present
/// while something is loaded; the shell reserves no space for it (it floats).
class DesktopNowPlayingBar extends ConsumerWidget {
  const DesktopNowPlayingBar({super.key});

  static const double height = 64;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playbackProvider.select((s) => s.currentAudio));
    if (track == null) return const SizedBox.shrink();
    final controller = ref.read(playbackProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        // A centred pill, not a full-width slab: capped so it reads as a
        // floating control on wide windows, shrinking to fit on narrow ones.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: GlassSurface(
            radius: 16,
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    // Left: artwork + title/artist → opens the full player.
                    Flexible(
                      flex: 5,
                      child: _NowPlayingLabel(track: track),
                    ),
                    const SizedBox(width: 12),
                    // Centre: transport over a scrubber.
                    Expanded(
                      flex: 6,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _Transport(controller: controller),
                          _Scrubber(controller: controller),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Right: volume, open full player, stop.
                    Flexible(
                      flex: 5,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _Volume(controller: controller),
                          const SizedBox(width: 4),
                          _BarButton(
                            tooltip: 'Open player',
                            icon: Icons.open_in_full,
                            onTap: () => openMusicPlayer(context),
                          ),
                          _BarButton(
                            tooltip: 'Stop',
                            icon: Icons.close,
                            color: scheme.onSurfaceVariant,
                            onTap: controller.stopAudio,
                          ),
                        ],
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

class _NowPlayingLabel extends ConsumerWidget {
  const _NowPlayingLabel({required this.track});
  final Playable track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = track.artwork ??
        (track.artworkUri == null
            ? null
            : ref
                .watch(artBytesProvider(track.artworkUri!.toString()))
                .asData
                ?.value);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => openMusicPlayer(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 44,
                height: 44,
                child: bytes != null
                    ? Image.memory(bytes,
                        fit: BoxFit.cover,
                        cacheWidth: 132,
                        gaplessPlayback: true)
                    : ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(Icons.music_note,
                            size: 18, color: scheme.onSurfaceVariant),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  if (track.subtitle.isNotEmpty)
                    Text(track.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.controller});
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _BarButton(
            tooltip: 'Previous',
            icon: Icons.skip_previous,
            size: 22,
            onTap: controller.previous),
        StreamBuilder<PlayerState>(
          stream: controller.player.playerStateStream,
          builder: (context, snap) {
            final playing = snap.data?.playing ?? false;
            return _BarButton(
              tooltip: playing ? 'Pause' : 'Play',
              icon: playing ? Icons.pause : Icons.play_arrow,
              size: 28,
              onTap: controller.togglePlay,
            );
          },
        ),
        _BarButton(
            tooltip: 'Next',
            icon: Icons.skip_next,
            size: 22,
            onTap: controller.next),
      ],
    );
  }
}

/// Thin position bar with elapsed / remaining labels flanking it.
class _Scrubber extends StatefulWidget {
  const _Scrubber({required this.controller});
  final PlaybackController controller;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  double? _dragValue;

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final player = widget.controller.player;
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, posSnap) {
        final duration = player.duration ?? Duration.zero;
        final position = posSnap.data ?? Duration.zero;
        final total = duration.inMilliseconds.toDouble();
        final value = _dragValue ??
            (total <= 0
                ? 0.0
                : position.inMilliseconds.clamp(0, total).toDouble());
        final remaining = duration - position;
        final labelStyle = TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 10,
            fontFeatures: const [FontFeature.tabularFigures()]);
        return Row(
          children: [
            SizedBox(
                width: 34,
                child: Text(_fmt(position),
                    textAlign: TextAlign.right, style: labelStyle)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: value,
                  max: total <= 0 ? 1 : total,
                  onChanged: total <= 0
                      ? null
                      : (v) => setState(() => _dragValue = v),
                  onChangeEnd: total <= 0
                      ? null
                      : (v) {
                          widget.controller
                              .seek(Duration(milliseconds: v.round()));
                          setState(() => _dragValue = null);
                        },
                ),
              ),
            ),
            SizedBox(
                width: 34,
                child: Text('-${_fmt(remaining)}', style: labelStyle)),
          ],
        );
      },
    );
  }
}

class _Volume extends StatelessWidget {
  const _Volume({required this.controller});
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<double>(
      stream: controller.player.volumeStream,
      builder: (context, snap) {
        final volume = (snap.data ?? controller.player.volume).clamp(0.0, 1.0);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(volume == 0 ? Icons.volume_off : Icons.volume_down,
                size: 16, color: scheme.onSurfaceVariant),
            SizedBox(
              width: 88,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: volume,
                  onChanged: controller.setVolume,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A compact icon button sized for the bar; keeps hit targets comfortable.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.size = 20,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: size,
      color: color,
      onPressed: onTap,
      icon: Icon(icon),
    );
  }
}
