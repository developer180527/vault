import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/platform/design/adaptive_icons.dart';
import '../../core/playback/playable.dart';
import '../../core/playback/playback_controller.dart';
import '../../features/media/data/server_music.dart';
import '../../features/media/music_player_page.dart';
import 'metrics.dart';

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
    const side = kMiniPlayerHeight - 12;
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
    final track = ref.watch(playbackProvider.select((s) => s.currentAudio));
    if (track == null) return const SizedBox.shrink();

    // Glass is provided by the enclosing GlassSurface; here we just add a
    // transparent Material so the InkWell splash renders on top of it.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // Guarded opener: a pill tap while the player is already up (or a
        // double-tap) must not stack a second copy.
        onTap: () => openMusicPlayer(context),
        child: SizedBox(
          height: kMiniPlayerHeight,
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
                onPressed: controller.next,
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}
