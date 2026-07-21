import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/logging/vault_log.dart';

final _log = VaultLog.tag('sync');

/// The caller's synced folders (provenance). Invalidated after a push/delete.
final syncedFoldersProvider = FutureProvider<List<SyncedFolderInfo>>((ref) {
  if (ref.watch(sessionProvider).asData?.value == null) return const [];
  return ref.watch(vaultClientProvider).sync.list();
});

/// Live progress of an in-flight push (null = idle).
class SyncProgress {
  const SyncProgress({
    required this.folder,
    required this.done,
    required this.total,
    this.current = '',
  });

  final String folder;
  final int done;
  final int total;
  final String current;

  double get fraction => total == 0 ? 0 : (done / total).clamp(0, 1);
}

class SyncProgressNotifier extends Notifier<SyncProgress?> {
  @override
  SyncProgress? build() => null;
  void set(SyncProgress? p) => state = p;
}

final syncProgressProvider =
    NotifierProvider<SyncProgressNotifier, SyncProgress?>(
        SyncProgressNotifier.new);

/// This device's origin label + platform, for a synced folder's provenance.
({String device, String platform}) _origin() {
  final platform = switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux => 'linux',
    _ => 'unknown',
  };
  // A friendly name: the machine hostname on desktop, the platform elsewhere.
  var device = platform;
  try {
    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      device = Platform.localHostname;
    }
  } catch (_) {}
  return (device: device, platform: platform);
}

/// Pick a local folder and push it into the vault as a synced folder. Returns
/// the created folder's id, or null if the user cancelled. Desktop/mobile:
/// [getDirectoryPath] returns a real directory path we can walk.
Future<String?> pickAndSyncFolder(WidgetRef ref) async {
  final dirPath = await getDirectoryPath();
  if (dirPath == null) return null;
  final dir = Directory(dirPath);
  if (!await dir.exists()) return null;

  final name = dirPath.split(Platform.pathSeparator).last;
  final api = ref.read(vaultClientProvider).sync;
  final origin = _origin();

  final (info, rootNodeId) = await api.create(
    name: name,
    originDevice: origin.device,
    originPlatform: origin.platform,
  );
  _log.info('synced folder created',
      fields: {'name': name, 'device': origin.device});

  // Enumerate files first (so we have a total for progress). Skip hidden
  // files and anything unreadable.
  final files = <File>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final base = entity.path.split(Platform.pathSeparator).last;
      if (!base.startsWith('.')) files.add(entity);
    }
  }

  ref.read(syncProgressProvider.notifier).set(
      SyncProgress(folder: name, done: 0, total: files.length));

  // Recreate the tree lazily: map a relative dir path → its server node id.
  final dirNodes = <String, String>{'': rootNodeId};
  var uploaded = 0;
  var totalBytes = 0;

  Future<String> nodeForDir(String relDir) async {
    if (dirNodes.containsKey(relDir)) return dirNodes[relDir]!;
    final parts = relDir.split('/');
    final parentRel = parts.sublist(0, parts.length - 1).join('/');
    final parentNode = await nodeForDir(parentRel);
    final id = await api.makeSubfolder(parentNode, parts.last);
    dirNodes[relDir] = id;
    return id;
  }

  for (final f in files) {
    final rel = f.path
        .substring(dirPath.length)
        .replaceAll(Platform.pathSeparator, '/')
        .replaceFirst(RegExp('^/'), '');
    final base = rel.contains('/') ? rel.substring(rel.lastIndexOf('/') + 1) : rel;
    final relDir = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
    ref.read(syncProgressProvider.notifier).set(
        SyncProgress(folder: name, done: uploaded, total: files.length, current: base));
    try {
      final len = await f.length();
      final parentNode = await nodeForDir(relDir);
      await api.uploadInto(parentNode, base, f.openRead(), len);
      totalBytes += len;
      uploaded++;
    } catch (e) {
      _log.warn('sync upload failed', fields: {'file': rel, 'err': '$e'});
    }
  }

  await api.touch(info.id, fileCount: uploaded, totalBytes: totalBytes);
  ref.read(syncProgressProvider.notifier).set(null);
  ref.invalidate(syncedFoldersProvider);
  _log.info('synced folder push done',
      fields: {'name': name, 'files': uploaded, 'bytes': totalBytes});
  return info.id;
}
