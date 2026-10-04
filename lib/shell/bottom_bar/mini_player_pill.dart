import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/debug/chrome_tuning.dart';
import '../../core/platform/design/adaptive_icons.dart';
import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import '../../features/media/data/server_music.dart';
import '../../features/media/music_player_page.dart';

/// Mini-player leading art: embedded bytes (local files) or bearer-cached
/// network art (server streams), music-note fallback.
class MiniArt extends ConsumerWidget {
  const MiniArt({super.key, required this.track});

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
    final side = ref.watch(chromeTuningProvider).miniHeight - 12;
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: SizedBox(
        width: side,
        height: side,
        child: bytes != null
            ? Image.memory(bytes,
                fit: BoxFit.cover, cacheWidth: 96, gaplessPlayback: true)
            : ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: AdaptiveIcon(VaultIcons.music,
                    size: 16, color: scheme.primary),
              ),
      ),
    );
  }
}

/// Thin now-playing pill: title, play/pause, next. Tapping it opens the
/// full-screen player (which hides the whole bottom stack).
class MiniPlayerPill extends ConsumerWidget {
  const MiniPlayerPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(playbackProvider.notifier);
    // select: rebuild on track changes only — video session churn is not this
    // pill's business.
    final tune = ref.watch(chromeTuningProvider);
    final real = ref.watch(playbackProvider.select((s) => s.currentAudio));
    // While tuning, stand in a fake track so the pill actually RENDERS. Without
    // this the dock squeezed open to make room for a pill that drew nothing,
    // which read as "the toggle does nothing".
    final track = real ?? (tune.forceMini ? _tuningPlaceholder : null);
    if (track == null) return const SizedBox.shrink();
    final demo = real == null;

    // Glass is provided by the enclosing GlassSurface; here we just add a
    // transparent Material so the InkWell splash renders on top of it.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // Guarded opener: a pill tap while the player is already up (or a
        // double-tap) must not stack a second copy.
        onTap: demo ? null : () => openMusicPlayer(context),
        child: SizedBox(
          height: tune.miniHeight,
          child: Row(
            children: [
              const SizedBox(width: 8),
              // Album art (embedded bytes or cached network art); the music
              // glyph is only the no-art fallback.
              ExcludeSemantics(child: MiniArt(track: track)),
              const SizedBox(width: 10),
              Expanded(
                child: Semantics(
                  label: 'Now playing: ${track.title}. Opens the player.',
                  button: true,
                  child: ExcludeSemantics(
                    child: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
              if (demo)
                const IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: AdaptiveIcon(VaultIcons.play, size: 20),
                  onPressed: null,
                )
              else
                StreamBuilder<PlayerState>(
                stream: controller.player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: playing ? 'Pause' : 'Play',
                    icon: AdaptiveIcon(
                      playing ? VaultIcons.pause : VaultIcons.play,
                      size: 20,
                    ),
                    onPressed: controller.togglePlay,
                  );
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Next track',
                icon: const AdaptiveIcon(VaultIcons.skipNext, size: 20),
                onPressed: demo ? null : controller.next,
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stand-in shown only while the tuning panel forces the mini-player on, so
/// its size can be dialled in without finding something to play.
final _tuningPlaceholder = Playable(
  id: '_tuning',
  kind: PlayableKind.audio,
  uri: Uri.parse('vault://tuning'),
  title: 'Sample Track — tuning',
);
