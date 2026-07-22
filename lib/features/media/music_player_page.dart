import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/client/vault_client.dart';
import '../../core/platform/audio_output.dart';
import '../../core/platform/platform_info.dart';
import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import 'data/dominant_color.dart';
import 'data/server_music.dart';

/// True while a [MusicPlayerPage] is on the navigator. Guards [openMusicPlayer]
/// so the full-screen player can never be pushed twice — the bug where tapping
/// a track while the mini-player pill was also live stacked two copies.
bool _playerOpen = false;

/// Open the full-screen player once, over the whole shell. Every entry point
/// (track tap, mini-player pill, desktop now-playing strip) routes through
/// here; a second call while it's already open is a no-op. The flag resets when
/// the route is popped.
void openMusicPlayer(BuildContext context) {
  if (_playerOpen) return;
  _playerOpen = true;
  Navigator.of(context, rootNavigator: true)
      .push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => const MusicPlayerPage(),
        ),
      )
      .whenComplete(() => _playerOpen = false);
}

/// Full-screen now-playing screen, styled after Apple Music: large artwork
/// (that shrinks when paused), a minimal capsule scrubber, a three-button
/// transport, a volume capsule, and a bottom row with shuffle / repeat and the
/// system audio-output picker labelled with the live device name. Swipe down
/// anywhere to minimize back to the mini-player. The background gradient is
/// tinted from the artwork's dominant color.
class MusicPlayerPage extends ConsumerStatefulWidget {
  const MusicPlayerPage({super.key});

  @override
  ConsumerState<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends ConsumerState<MusicPlayerPage>
    with SingleTickerProviderStateMixin {
  // Swipe-down-to-dismiss: the whole page follows the finger, then either pops
  // (past a distance/velocity threshold) or springs back.
  double _dragY = 0;
  late final AnimationController _spring =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  Animation<double> _back = const AlwaysStoppedAnimation(0);

  @override
  void initState() {
    super.initState();
    _spring.addListener(() => setState(() => _dragY = _back.value));
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _spring.stop();
    setState(() => _dragY = (_dragY + d.delta.dy).clamp(0.0, double.infinity));
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (_dragY > 140 || v > 800) {
      Navigator.of(context).maybePop();
    } else {
      _back = Tween(begin: _dragY, end: 0.0)
          .animate(CurvedAnimation(parent: _spring, curve: Curves.easeOutCubic));
      _spring.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(playbackProvider.notifier);
    final player = controller.player;
    final track = ref.watch(playbackProvider.select((s) => s.currentAudio));
    final scheme = Theme.of(context).colorScheme;

    final hasArt = track != null &&
        (track.artwork != null || track.artworkUri != null);
    final artColor =
        hasArt ? ref.watch(artColorProvider(track.id)).asData?.value : null;

    // Drag feedback: shrink + round the page as it slides down.
    final progress = (_dragY / 320).clamp(0.0, 1.0);
    final dragScale = 1 - 0.06 * progress;

    final page = Transform.translate(
      offset: Offset(0, _dragY),
      child: Transform.scale(
        scale: dragScale,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(progress > 0 ? 28 : 0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  artColor == null
                      ? scheme.primaryContainer
                      : Color.lerp(artColor, scheme.surface, 0.25)!,
                  scheme.surface,
                ],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 16),
                child: LayoutBuilder(builder: (context, constraints) {
                  final wide = constraints.maxWidth > 720;
                  return wide
                      ? _wideLayout(context, controller, player, track)
                      : _phoneLayout(context, controller, player, track);
                }),
              ),
            ),
          ),
        ),
      ),
    );

    // Swipe-to-dismiss is captured ONLY from the top 60% (the grabber + art),
    // so it never fights the sliders/controls in the lower part of the screen
    // for a vertical drag.
    final dragHeight = MediaQuery.sizeOf(context).height * 0.6;
    return Scaffold(
      body: Stack(
        children: [
          page,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: dragHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
            ),
          ),
        ],
      ),
    );
  }

  Widget _grabber(BuildContext context) => Center(
        child: Container(
          width: 40,
          height: 5,
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurfaceVariant
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(2.5),
          ),
        ),
      );

  Widget _phoneLayout(BuildContext context, PlaybackController controller,
      AudioPlayer player, Playable? track) {
    return Column(
      children: [
        _grabber(context),
        const Spacer(flex: 2),
        _AnimatedArtwork(
            player: player, art: track?.artwork, artUri: track?.artworkUri),
        const Spacer(flex: 2),
        _TitleRow(track: track, controller: controller),
        const SizedBox(height: 18),
        _SeekBar(player: player),
        const SizedBox(height: 10),
        _TransportControls(controller: controller, player: player),
        const SizedBox(height: 22),
        _VolumeBar(player: player),
        const SizedBox(height: 14),
        _OutputRow(controller: controller),
      ],
    );
  }

  Widget _wideLayout(BuildContext context, PlaybackController controller,
      AudioPlayer player, Playable? track) {
    return Column(
      children: [
        _grabber(context),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Row(
                children: [
                  Expanded(
                    child: Center(
                      child: _AnimatedArtwork(
                          player: player,
                          art: track?.artwork,
                          artUri: track?.artworkUri),
                    ),
                  ),
                  const SizedBox(width: 40),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _TitleRow(track: track, controller: controller),
                        const SizedBox(height: 24),
                        _SeekBar(player: player),
                        const SizedBox(height: 16),
                        _TransportControls(
                            controller: controller, player: player),
                        const SizedBox(height: 28),
                        _VolumeBar(player: player),
                        const SizedBox(height: 14),
                        _OutputRow(controller: controller),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A minimal Apple-Music capsule slider: a rounded two-tone track, no knob at
/// rest, thickening (with a small thumb) only while [active] (being dragged).
SliderThemeData _capsuleSlider(ColorScheme scheme, {required bool active}) {
  return SliderThemeData(
    trackHeight: active ? 10 : 7,
    activeTrackColor: scheme.onSurface.withValues(alpha: 0.92),
    inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.20),
    thumbColor: Colors.white,
    trackShape: const RoundedRectSliderTrackShape(),
    // A generous invisible overlay = a big, finger-friendly grab area even
    // though the track itself stays thin.
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
    overlayColor: scheme.onSurface.withValues(alpha: 0.08),
    thumbShape: RoundSliderThumbShape(
        enabledThumbRadius: active ? 8 : 0, elevation: active ? 2 : 0),
  );
}

/// Wraps a capsule [Slider] in a taller touch strip so big fingers can grab the
/// thin track anywhere across a comfortable vertical band.
class _TouchSlider extends StatelessWidget {
  const _TouchSlider({required this.data, required this.child});
  final SliderThemeData data;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: SliderTheme(data: data, child: child),
      );
}

/// Album art that shrinks when paused (Apple Music), enlarges while playing.
class _AnimatedArtwork extends StatelessWidget {
  const _AnimatedArtwork({required this.player, this.art, this.artUri});

  final AudioPlayer player;
  final Uint8List? art;
  final Uri? artUri;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: player.playerStateStream,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        return AnimatedScale(
          scale: playing ? 1.0 : 0.82,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          child: _Artwork(art: art, artUri: artUri),
        );
      },
    );
  }
}

class _Artwork extends ConsumerWidget {
  const _Artwork({this.art, this.artUri});

  final Uint8List? art;
  final Uri? artUri;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final side = MediaQuery.sizeOf(context).width.clamp(200.0, 380.0) - 40;
    final fallback =
        Icon(Icons.music_note, size: side * 0.4, color: scheme.primary);
    final bytes = art ??
        (artUri == null
            ? null
            : ref.watch(artBytesProvider(artUri!.toString())).asData?.value);
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 44,
            offset: const Offset(0, 22),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes != null
          ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
          : fallback,
    );
  }
}

/// Title + artist on the left; the favorite star and a "⋯" more menu on the
/// right — the Apple Music header. Extra actions (Stop) live in the menu.
class _TitleRow extends ConsumerWidget {
  const _TitleRow({required this.track, required this.controller});
  final Playable? track;
  final PlaybackController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track?.title ?? 'Nothing playing',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                (track?.subtitle.isEmpty ?? true)
                    ? 'Local music'
                    : track!.subtitle,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (track != null) _FavoriteButton(trackId: track!.id),
        _MoreButton(controller: controller),
      ],
    );
  }
}

/// The "⋯" menu — Apple Music's overflow. Stop lives here (kills playback,
/// clears the queue, removes the mini-player) rather than cluttering the
/// transport.
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.controller});
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: 'More',
      style: IconButton.styleFrom(
        backgroundColor: scheme.onSurface.withValues(alpha: 0.10),
      ),
      icon: const Icon(Icons.more_horiz, size: 22),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined),
                title: const Text('Stop'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await controller.stopAudio();
                  if (context.mounted) Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Heart toggle for the playing track. Only rendered while connected — local
/// standalone playback has no server-side favorites.
class _FavoriteButton extends ConsumerWidget {
  const _FavoriteButton({required this.trackId});
  final String trackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(musicServerModeProvider)) return const SizedBox.shrink();
    final liked = ref.watch(
      favoriteIdsProvider.select((ids) => ids.contains(trackId)),
    );
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: liked ? 'Remove from Favorites' : 'Add to Favorites',
      style: IconButton.styleFrom(
        backgroundColor: scheme.onSurface.withValues(alpha: 0.10),
      ),
      icon: Icon(
        liked ? Icons.star : Icons.star_border,
        size: 22,
        color: liked ? scheme.primary : null,
      ),
      onPressed: () async {
        final music = ref.read(vaultClientProvider).music;
        try {
          if (liked) {
            await music.removeFavorite(trackId);
          } else {
            await music.addFavorite(trackId);
          }
          ref.invalidate(favoritesProvider);
        } catch (_) {
          // Personal-zone tracks aren't in the shared catalog.
        }
      },
    );
  }
}

/// Position scrubber — a minimal capsule that thickens while dragging, with
/// elapsed on the left and REMAINING (−m:ss) on the right, Apple Music-style.
class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player});
  final AudioPlayer player;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  AudioPlayer get player => widget.player;

  late final Stream<Duration> _position = player.createPositionStream(
    minPeriod: const Duration(milliseconds: 200),
    maxPeriod: const Duration(milliseconds: 500),
  );

  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<Duration>(
      stream: _position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final total = player.duration ?? Duration.zero;
        final max = total.inMilliseconds.toDouble().clamp(1.0, double.infinity);

        if (_dragMs != null &&
            (position.inMilliseconds - _dragMs!).abs() < 1000) {
          _dragMs = null;
        }
        final shown =
            (_dragMs ?? position.inMilliseconds.toDouble()).clamp(0.0, max);
        final remaining =
            Duration(milliseconds: (max - shown).round());

        return Column(
          children: [
            _TouchSlider(
              data: _capsuleSlider(scheme, active: _dragMs != null),
              child: Slider(
                value: shown,
                max: max,
                onChangeStart: (v) => setState(() => _dragMs = v),
                onChanged: (v) => setState(() => _dragMs = v),
                onChangeEnd: (v) =>
                    player.seek(Duration(milliseconds: v.round())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(Duration(milliseconds: shown.round())),
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 12)),
                  Text('-${_fmt(remaining)}',
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 12)),
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

/// The three-button transport: previous, play/pause, next. Plain monochrome
/// icons (no filled circle), like Apple Music. Shuffle/repeat moved to the
/// output row below.
class _TransportControls extends StatelessWidget {
  const _TransportControls({required this.controller, required this.player});
  final PlaybackController controller;
  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          iconSize: 44,
          color: color,
          icon: const Icon(Icons.skip_previous),
          onPressed: controller.previous,
        ),
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            return IconButton(
              iconSize: 68,
              color: color,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              onPressed: controller.togglePlay,
            );
          },
        ),
        IconButton(
          iconSize: 44,
          color: color,
          icon: const Icon(Icons.skip_next),
          onPressed: controller.next,
        ),
      ],
    );
  }
}

/// Volume capsule with speaker icons flanking it.
class _VolumeBar extends StatelessWidget {
  const _VolumeBar({required this.player});
  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.volume_down, size: 18, color: scheme.onSurfaceVariant),
        Expanded(
          child: StreamBuilder<double>(
            stream: player.volumeStream,
            builder: (context, snap) {
              final volume = (snap.data ?? player.volume).clamp(0.0, 1.0);
              return _TouchSlider(
                data: _capsuleSlider(scheme, active: false),
                child: Slider(value: volume, onChanged: player.setVolume),
              );
            },
          ),
        ),
        Icon(Icons.volume_up, size: 18, color: scheme.onSurfaceVariant),
      ],
    );
  }
}

/// The bottom row: shuffle (left), repeat (next to the output button), and the
/// system audio-output picker with the live device name — Apple Music's
/// bottom cluster.
class _OutputRow extends ConsumerWidget {
  const _OutputRow({required this.controller});
  final PlaybackController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final shuffle = ref.watch(playbackProvider.select((s) => s.shuffle));
    final repeat = ref.watch(playbackProvider.select((s) => s.repeat));

    final shuffleBtn = IconButton(
      tooltip: 'Shuffle',
      icon: const Icon(Icons.shuffle, size: 22),
      color: shuffle ? scheme.primary : scheme.onSurfaceVariant,
      onPressed: () => controller.setShuffle(!shuffle),
    );
    final repeatBtn = IconButton(
      tooltip: 'Repeat',
      icon: Icon(repeat == LoopMode.one ? Icons.repeat_one : Icons.repeat,
          size: 22),
      color: repeat != LoopMode.off ? scheme.primary : scheme.onSurfaceVariant,
      onPressed: controller.cycleRepeat,
    );

    // Non-iOS: no system route picker — just center shuffle + repeat.
    if (!isIOS) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [shuffleBtn, const SizedBox(width: 8), repeatBtn],
      );
    }

    final picker = SizedBox(
      width: 34,
      height: 34,
      child: UiKitView(
        viewType: 'vault/route-picker',
        creationParams: {'tint': scheme.onSurface.toARGB32()},
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );

    // The picker sits DEAD-CENTRE (equal Expanded flanks). Repeat is pinned
    // right beside it (left flank, end-aligned), shuffle to repeat's left. The
    // device name is a full-width centered line below, so it sits under the
    // centered picker without widening the row and shoving the buttons away.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [shuffleBtn, const SizedBox(width: 4), repeatBtn],
              ),
            ),
            const SizedBox(width: 10),
            picker,
            const SizedBox(width: 10),
            const Expanded(child: SizedBox()),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          ref.watch(audioOutputNameProvider).asData?.value ?? '',
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
      ],
    );
  }
}
