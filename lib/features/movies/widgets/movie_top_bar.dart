import 'package:flutter/material.dart';

import '../../../core/models/server_movie.dart';

/// The player's top chrome: back, title, audio-language and subtitle pickers.
///
/// Shared by BOTH engines. The menus are driven by the server's stream
/// descriptor rather than by whatever the decoder reports, so the labels are
/// identical no matter who is decoding — "Japanese (Original)" reads the same
/// on the native path and the libmpv path, and the selection is an ordinal
/// that each engine applies its own way (native re-requests the stream,
/// libmpv switches in place).
class MovieTopBar extends StatelessWidget {
  const MovieTopBar({
    super.key,
    required this.movie,
    required this.audio,
    required this.subKey,
    required this.onBack,
    required this.onAudio,
    required this.onSubtitle,
    this.busy = false,
  });

  final ServerMovie movie;
  final int audio;

  /// null = subtitles off, else the track key ("e0" / "x1").
  final String? subKey;
  final VoidCallback onBack;
  final ValueChanged<int> onAudio;
  final ValueChanged<String?> onSubtitle;

  /// Shows a small spinner in place of nothing while an engine-level switch is
  /// in flight (the native path restarts the stream, which isn't instant).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final selectableAudio = movie.audio.length > 1;
    final selectableSubs = movie.subs.where((s) => s.text).toList();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.5), Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              movie.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white70),
              ),
            ),
          if (selectableAudio)
            MovieAudioMenu(movie: movie, current: audio, onSelect: onAudio),
          if (selectableSubs.isNotEmpty)
            MovieSubMenu(
                subs: selectableSubs, current: subKey, onSelect: onSubtitle),
        ],
      ),
    );
  }
}

class MovieAudioMenu extends StatelessWidget {
  const MovieAudioMenu({
    super.key,
    required this.movie,
    required this.current,
    required this.onSelect,
  });
  final ServerMovie movie;
  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Audio track',
      icon: const Icon(Icons.multitrack_audio, color: Colors.white),
      initialValue: current,
      onSelected: onSelect,
      itemBuilder: (context) => [
        for (final a in movie.audio)
          PopupMenuItem(
            value: a.index,
            child: Row(
              children: [
                Icon(Icons.check,
                    size: 16,
                    color: a.index == current
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent),
                const SizedBox(width: 8),
                Text(a.label),
              ],
            ),
          ),
      ],
    );
  }
}

class MovieSubMenu extends StatelessWidget {
  const MovieSubMenu({
    super.key,
    required this.subs,
    required this.current,
    required this.onSelect,
  });
  final List<MovieSub> subs;
  final String? current;
  final ValueChanged<String?> onSelect;

  /// The track key the server expects: `e<embedded idx>` or `x<sidecar idx>`.
  static String keyFor(List<MovieSub> subs, MovieSub s) {
    if (s.isExternal) {
      final externals = subs.where((x) => x.isExternal).toList();
      return 'x${externals.indexOf(s)}';
    }
    return 'e${s.index}';
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String?>(
      tooltip: 'Subtitles',
      icon: Icon(
        current == null ? Icons.subtitles_outlined : Icons.subtitles,
        color: Colors.white,
      ),
      onSelected: onSelect,
      itemBuilder: (context) => [
        PopupMenuItem<String?>(
          value: null,
          child: _row(context, 'Off', current == null),
        ),
        for (final s in subs)
          PopupMenuItem<String?>(
            value: keyFor(subs, s),
            child: _row(context, s.label, keyFor(subs, s) == current),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, String label, bool selected) => Row(
        children: [
          Icon(Icons.check,
              size: 16,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent),
          const SizedBox(width: 8),
          Text(label),
        ],
      );
}

/// Shown when a stream can't be opened at all.
class PlayerErrorView extends StatelessWidget {
  const PlayerErrorView({super.key, required this.onBack, this.detail});

  final VoidCallback onBack;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white54, size: 40),
            const SizedBox(height: 12),
            const Text('Playback failed',
                style: TextStyle(color: Colors.white70)),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(detail!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
            const SizedBox(height: 12),
            TextButton(onPressed: onBack, child: const Text('Go back')),
          ],
        ),
      ),
    );
  }
}
