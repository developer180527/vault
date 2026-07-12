import '../../../core/logging/vault_log.dart';

final _log = VaultLog.tag('player.reg');

/// Tracks every live [VideoPlayerController] so leaks are *measurable*: after a
/// player closes, the alive count must return to 0. If it doesn't, a controller
/// (and its audio) is still running. Each open/close logs the count, giving a
/// definitive trace in the in-app log viewer.
class PlayerRegistry {
  PlayerRegistry._();

  static int _nextInstance = 0;
  static final Map<int, String> _alive = {};

  static int get aliveCount => _alive.length;

  /// Call when a controller is created. Returns its instance id.
  static int open(String mediaId) {
    final instance = ++_nextInstance;
    _alive[instance] = mediaId;
    _log.info('controller OPENED', fields: {
      'instance': instance,
      'media': mediaId,
      'aliveCount': _alive.length,
    });
    return instance;
  }

  /// Call after a controller has been fully disposed.
  static void close(int instance, String mediaId) {
    _alive.remove(instance);
    _log.info('controller CLOSED', fields: {
      'instance': instance,
      'media': mediaId,
      'aliveCount': _alive.length,
      if (_alive.isNotEmpty) 'stillAlive': _alive.toString(),
    });
  }
}
