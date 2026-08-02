import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/playback/mpv_engine.dart';
import '../../core/playback/playable.dart';

/// Opens the experimental libmpv player.
Future<void> openMpvPlayer(BuildContext context, Playable item) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => MpvPlayerPage(item: item)),
  );
}

/// The libmpv player (media_kit) — the evaluation surface for replacing
/// video_player.
///
/// What's different from the AVPlayer/ExoPlayer path: the audio and subtitle
/// menus here are read from the FILE and switched **in-player**. No server
/// remux, no stream restart, no rebuffer — and MKV opens natively instead of
/// needing a container rewrite first.
class MpvPlayerPage extends StatefulWidget {
  const MpvPlayerPage({super.key, required this.item});

  final Playable item;

  @override
  State<MpvPlayerPage> createState() => _MpvPlayerPageState();
}

class _MpvPlayerPageState extends State<MpvPlayerPage> {
  late final MpvEngine _engine;
  MpvState _state = const MpvState();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _engine = MpvEngine();
    _engine.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _engine.open(widget.item);
  }

  @override
  void dispose() {
    _engine.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // libmpv renders into this texture; it also draws embedded ASS/PGS
          // subtitles itself, which the AVPlayer path can't do at all.
          Video(controller: _engine.controller, controls: NoVideoControls),

          if (_state.buffering)
            const Center(child: CircularProgressIndicator(color: Colors.white)),

          if (_state.error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Playback failed: ${_state.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              ),
            ),

          // Top bar: back + the in-player track menus.
          SafeArea(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.5),
                    Colors.transparent,
                  ],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  const _Badge(),
                  if (_state.canSwitchAudio)
                    _TrackMenu(
                      icon: Icons.multitrack_audio,
                      tooltip: 'Audio language',
                      tracks: _state.audioTracks,
                      currentId: _state.currentAudioId,
                      onSelect: _engine.setAudioTrack,
                    ),
                  if (_state.hasSubtitles)
                    _TrackMenu(
                      icon: Icons.subtitles_outlined,
                      tooltip: 'Subtitles',
                      tracks: _state.subtitleTracks,
                      currentId: _state.currentSubtitleId,
                      allowOff: true,
                      onSelect: _engine.setSubtitleTrack,
                    ),
                ],
              ),
            ),
          ),

          // Transport: play/pause + a scrubber driven by the engine's streams.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.6),
                    Colors.transparent,
                  ],
                ),
              ),
              padding: EdgeInsets.only(
                top: 24,
                bottom: MediaQuery.paddingOf(context).bottom + 8,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    iconSize: 56,
                    color: Colors.white,
                    icon: Icon(_state.playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill),
                    onPressed: _engine.playPause,
                  ),
                  _MpvScrubber(engine: _engine, duration: _state.duration),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Marks this as the experimental engine, so a tester always knows which
/// player produced a result.
class _Badge extends StatelessWidget {
  const _Badge();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 8),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.white24,
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Text('mpv',
        style: TextStyle(color: Colors.white, fontSize: 11)),
  );
}

class _TrackMenu extends StatelessWidget {
  const _TrackMenu({
    required this.icon,
    required this.tooltip,
    required this.tracks,
    required this.currentId,
    required this.onSelect,
    this.allowOff = false,
  });

  final IconData icon;
  final String tooltip;
  final List<MpvTrack> tracks;
  final String currentId;
  final ValueChanged<String> onSelect;
  final bool allowOff;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: tooltip,
      icon: Icon(icon, color: Colors.white),
      onSelected: onSelect,
      itemBuilder: (context) => [
        if (allowOff)
          _row(context, 'no', 'Off', currentId == 'no'),
        for (final t in tracks)
          _row(context, t.id, t.label, t.id == currentId),
      ],
    );
  }

  PopupMenuItem<String> _row(
          BuildContext context, String id, String label, bool selected) =>
      PopupMenuItem<String>(
        value: id,
        child: Row(
          children: [
            Icon(Icons.check,
                size: 16,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      );
}

/// mm:ss (h:mm:ss past an hour).
String _fmt(Duration d) {
  final h = d.inHours;
  final m = (d.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Position scrubber fed by the engine's position stream. Same drag-latching
/// behaviour as the AVPlayer scrubber: the thumb follows the finger and stays
/// put until playback catches up to the seek target.
class _MpvScrubber extends StatefulWidget {
  const _MpvScrubber({required this.engine, required this.duration});

  final MpvEngine engine;
  final Duration duration;

  @override
  State<_MpvScrubber> createState() => _MpvScrubberState();
}

class _MpvScrubberState extends State<_MpvScrubber> {
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.engine.positionStream,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final max =
            widget.duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
        if (_dragMs != null && (pos.inMilliseconds - _dragMs!).abs() < 1000) {
          _dragMs = null;
        }
        final shown =
            (_dragMs ?? pos.inMilliseconds.toDouble()).clamp(0.0, max);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(_fmt(Duration(milliseconds: shown.round())),
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: shown,
                  max: max,
                  onChanged: (v) => setState(() => _dragMs = v),
                  onChangeEnd: (v) =>
                      widget.engine.seek(Duration(milliseconds: v.round())),
                ),
              ),
              Text(_fmt(widget.duration),
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        );
      },
    );
  }
}
