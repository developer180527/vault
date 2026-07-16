import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists per-item playback position so video/audio resumes where you left
/// off. Keyed by media id; the server-backed sync can later mirror this across
/// devices, but locally it's just a small preference.
class PlaybackPositionStore {
  static const _prefix = 'playpos_';

  /// Below this we don't bother resuming (treat as "start over").
  static const _minResume = Duration(seconds: 5);

  Future<Duration?> get(String mediaId) async {
    final prefs = await SharedPreferences.getInstance();
    final seconds = prefs.getInt('$_prefix$mediaId');
    if (seconds == null) return null;
    final pos = Duration(seconds: seconds);
    return pos >= _minResume ? pos : null;
  }

  Future<void> save(String mediaId, Duration position, Duration total) async {
    final prefs = await SharedPreferences.getInstance();
    // Clear when finished (within 5s of the end) so it restarts next time.
    if (total > Duration.zero && position >= total - const Duration(seconds: 5)) {
      await prefs.remove('$_prefix$mediaId');
    } else {
      await prefs.setInt('$_prefix$mediaId', position.inSeconds);
    }
  }
}

final playbackPositionStoreProvider =
    Provider<PlaybackPositionStore>((ref) => PlaybackPositionStore());
