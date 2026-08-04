import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/capability/capability.dart';
import '../../../core/capability/manifest_providers.dart';
import '../../../core/client/vault_client.dart';

/// How often the transfer view refreshes while it's on screen.
///
/// Polling, deliberately, rather than the change feed: that feed exists to say
/// "the LIBRARY changed, re-fetch it". Torrent speeds and ETAs change every
/// second and are worthless a minute later — pushing them would be a firehose
/// of events nobody stores. Two seconds matches qBittorrent's own WebUI and is
/// cheap over a tailnet.
const _pollInterval = Duration(seconds: 2);

/// The caller's torrents, refreshed while something is watching.
///
/// autoDispose is the point: the timer only exists while the Torrent tab is
/// mounted. Leaving a 2s poll running behind other tabs would keep waking a
/// phone's radio for a screen nobody is looking at.
final torrentListProvider =
    StreamProvider.autoDispose<List<TorrentEntry>>((ref) async* {
  if (ref.watch(sessionProvider).asData?.value == null) {
    yield const [];
    return;
  }
  final api = ref.watch(vaultClientProvider).torrents;
  while (true) {
    yield await api.list();
    await Future<void>.delayed(_pollInterval);
  }
});

/// Global speeds/limits, on the same cadence.
final transferStatsProvider =
    StreamProvider.autoDispose<TransferStats>((ref) async* {
  if (ref.watch(sessionProvider).asData?.value == null) return;
  final api = ref.watch(vaultClientProvider).torrents;
  while (true) {
    yield await api.transfer();
    await Future<void>.delayed(_pollInterval);
  }
});

/// Whether the caller may mutate torrents (pause/remove/add).
final canManageTorrentsProvider = Provider<bool>((ref) {
  if (ref.watch(sessionProvider).asData?.value == null) return false;
  return ref.watch(
      canProvider((serviceId: 'torrent', action: CapabilityAction.write)));
});

/// Human-readable byte size.
String formatBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

/// Transfer rate. Returns '' for zero so idle rows stay quiet instead of
/// showing a column of "0 B/s".
String formatSpeed(int bytesPerSecond) =>
    bytesPerSecond <= 0 ? '' : '${formatBytes(bytesPerSecond)}/s';

/// Coarse remaining time — minutes matter, seconds don't.
String formatEta(int seconds) {
  if (seconds <= 0 || seconds >= 8640000) return '';
  final d = Duration(seconds: seconds);
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// A short, human label for qBittorrent's raw state string. Unknown states
/// fall through to the raw value rather than being mislabelled — qBittorrent
/// adds states between versions.
String describeState(TorrentEntry t) {
  switch (t.state) {
    case 'downloading':
    case 'forcedDL':
      return 'Downloading';
    case 'metaDL':
    case 'forcedMetaDL':
      return 'Fetching metadata';
    case 'stalledDL':
      return 'Stalled — no seeds';
    case 'uploading':
    case 'forcedUP':
      return 'Seeding';
    case 'stalledUP':
      return 'Seeding — idle';
    case 'pausedDL':
    case 'stoppedDL':
      return 'Paused';
    case 'pausedUP':
    case 'stoppedUP':
      return 'Finished';
    case 'queuedDL':
    case 'queuedUP':
      return 'Queued';
    case 'checkingDL':
    case 'checkingUP':
    case 'checkingResumeData':
      return 'Checking';
    case 'moving':
      return 'Moving';
    case 'error':
      return 'Error';
    case 'missingFiles':
      return 'Files missing';
    default:
      return t.state;
  }
}
