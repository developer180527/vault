import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/platform/design/adaptive_icons.dart';
import '../../core/playback/playback_controller.dart';
import '../../features/media/music_player_page.dart';

/// Compact global now-playing control for the sidebar-shell form factors:
/// title (tap → full player), play/pause, next, stop. Rendered CENTERED in
/// the desktop title bar (per design: playback status lives in the window
/// chrome, like a browser's tab-audio indicator), and in the sidebar on
/// tablets, which have no title bar. Nothing renders while no audio plays.
class NowPlayingStrip extends ConsumerWidget {
  const NowPlayingStrip({super.key, this.maxTitleWidth = 220});

  final double maxTitleWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select: the title-bar strip re-renders per TRACK, not per playback event.
    final track = ref.watch(playbackProvider.select((s) => s.currentAudio));
    if (track == null) return const SizedBox.shrink();
    final controller = ref.read(playbackProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: 'Now playing: ${track.title}. Opens the player.',
            child: InkWell(
              onTap: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (_) => const MusicPlayerPage(),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: AdaptiveIcon(
                        VaultIcons.music,
                        size: 13,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxTitleWidth),
                      child: ExcludeSemantics(
                        child: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          StreamBuilder<PlayerState>(
            stream: controller.player.playerStateStream,
            builder: (context, snapshot) {
              final playing = snapshot.data?.playing ?? false;
              return _StripButton(
                tooltip: playing ? 'Pause' : 'Play',
                icon: playing ? VaultIcons.pause : VaultIcons.play,
                onPressed: controller.togglePlay,
              );
            },
          ),
          _StripButton(
            tooltip: 'Next track',
            icon: VaultIcons.skipNext,
            onPressed: controller.next,
          ),
          _StripButton(
            tooltip: 'Stop playback',
            icon: VaultIcons.close,
            onPressed: controller.stopAudio,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

/// Icon button sized to fit the 40px title bar.
class _StripButton extends StatelessWidget {
  const _StripButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final AdaptiveIconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: ExcludeSemantics(child: AdaptiveIcon(icon, size: 15)),
          ),
        ),
      ),
    );
  }
}
