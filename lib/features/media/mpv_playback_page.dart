import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/playback/mpv_engine.dart';
import '../../core/playback/playable.dart';
import 'widgets/video_surface.dart';
import 'widgets/video_transport.dart';

/// The generic libmpv playback page — the Files/media counterpart to
/// [MpvMoviePlayerPage], for any [Playable] of kind video.
///
/// Wears the same [VideoSurface] chrome as the native page, so a dual-audio
/// MKV sitting in Files looks and behaves exactly like one in the catalog.
/// Where the server declared tracks they're used for their nicer labels;
/// otherwise mpv's own enumeration fills the picker.
class MpvPlaybackPage extends StatefulWidget {
  const MpvPlaybackPage({super.key, required this.item});

  final Playable item;

  @override
  State<MpvPlaybackPage> createState() => _MpvPlaybackPageState();
}

class _MpvPlaybackPageState extends State<MpvPlaybackPage> {
  late final MpvEngine _engine = MpvEngine();
  late final MpvTransport _transport = MpvTransport(_engine);

  MpvState _state = const MpvState();
  StreamSubscription<MpvState>? _sub;
  int _audio = 0;
  bool _opening = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _sub = _engine.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    unawaited(_open());
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _transport.dispose();
    unawaited(_engine.dispose());
    super.dispose();
  }

  Future<void> _open() async {
    try {
      await _engine.open(widget.item);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// Prefer the server's labels ("English (Dub)") when it declared any; fall
  /// back to what libmpv read out of the container.
  List<AudioTrackOption> get _tracks {
    if (widget.item.audioTracks.length > 1) return widget.item.audioTracks;
    return [
      for (var i = 0; i < _state.audioTracks.length; i++)
        AudioTrackOption(
          index: i,
          label: _state.audioTracks[i].label,
          isDefault: i == 0,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.item.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Builder(
        builder: (context) {
          if (_error != null || _state.error != null) {
            return Center(
              child: Text('Playback failed: ${_error ?? _state.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
            );
          }
          if (_opening) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
          return VideoSurface.mpv(
            transport: _transport,
            picture: _engine.videoWidget(),
            title: widget.item.title,
            audioTracks: _tracks,
            currentAudioTrack: _audio,
            // In-player switch: instant, no stream swap, position preserved.
            onSelectAudio: (i) async {
              setState(() => _audio = i);
              await _engine.setAudioTrackAt(i);
            },
          );
        },
      ),
    );
  }
}
