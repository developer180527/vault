import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A read-only inspector for everything Vault stores on THIS device: the app's
/// on-disk directories (with per-entry sizes), the key/value preferences, and
/// which keys live in the secure keystore (values stay hidden — they're
/// tokens). Useful for "what is this app keeping?" and for debugging.

/// One top-level entry inside a storage directory.
class StorageEntry {
  const StorageEntry(this.name, this.bytes, this.isDir);
  final String name;
  final int bytes;
  final bool isDir;
}

/// One inspected directory: its total size and immediate children.
class StoreDir {
  const StoreDir(this.label, this.path, this.bytes, this.entries);
  final String label;
  final String path;
  final int bytes;
  final List<StorageEntry> entries;
}

class LocalData {
  const LocalData({
    required this.dirs,
    required this.prefs,
    required this.secureKeys,
  });
  final List<StoreDir> dirs;
  final Map<String, String> prefs;
  final List<String> secureKeys;

  int get totalBytes => dirs.fold(0, (a, d) => a + d.bytes);
}

Future<int> _sizeOf(FileSystemEntity e) async {
  try {
    if (e is File) return await e.length();
    if (e is Directory) {
      var total = 0;
      await for (final c in e.list(recursive: true, followLinks: false)) {
        if (c is File) {
          try {
            total += await c.length();
          } catch (_) {}
        }
      }
      return total;
    }
  } catch (_) {}
  return 0;
}

final localDataProvider = FutureProvider.autoDispose<LocalData>((ref) async {
  final dirs = <StoreDir>[];

  Future<void> add(String label, Future<Directory> Function() get) async {
    try {
      final d = await get();
      if (!await d.exists()) return;
      // Skip duplicates (some platforms alias these directories).
      if (dirs.any((x) => x.path == d.path)) return;
      final entries = <StorageEntry>[];
      var total = 0;
      await for (final c in d.list(followLinks: false)) {
        final s = await _sizeOf(c);
        total += s;
        entries.add(StorageEntry(c.path.split(Platform.pathSeparator).last, s,
            c is Directory));
      }
      entries.sort((a, b) => b.bytes.compareTo(a.bytes));
      dirs.add(StoreDir(label, d.path, total, entries));
    } catch (_) {}
  }

  await add('Documents', getApplicationDocumentsDirectory);
  await add('App support', getApplicationSupportDirectory);
  await add('Cache', getApplicationCacheDirectory);
  await add('Temporary', getTemporaryDirectory);

  final prefs = await SharedPreferences.getInstance();
  final prefMap = <String, String>{
    for (final k in prefs.getKeys()) k: '${prefs.get(k)}',
  };

  var secureKeys = <String>[];
  try {
    secureKeys =
        (await const FlutterSecureStorage().readAll()).keys.toList()..sort();
  } catch (_) {}

  return LocalData(dirs: dirs, prefs: prefMap, secureKeys: secureKeys);
});

String fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var size = bytes / 1024;
  var i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(1)} ${units[i]}';
}

class LocalDataPage extends ConsumerWidget {
  const LocalDataPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(localDataProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Local data'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(localDataProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not read storage: $e')),
        data: (d) => ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.sd_storage),
              title: const Text('Total on-disk'),
              trailing: Text(fmtBytes(d.totalBytes),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(),
            for (final dir in d.dirs)
              ExpansionTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(dir.label),
                subtitle: Text(dir.path,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text(fmtBytes(dir.bytes)),
                childrenPadding: const EdgeInsets.only(left: 16),
                children: dir.entries.isEmpty
                    ? [
                        const ListTile(
                            dense: true, title: Text('(empty)')),
                      ]
                    : [
                        for (final e in dir.entries)
                          ListTile(
                            dense: true,
                            leading: Icon(
                                e.isDir
                                    ? Icons.folder
                                    : Icons.insert_drive_file_outlined,
                                size: 18),
                            title: Text(e.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: Text(fmtBytes(e.bytes),
                                style: Theme.of(context).textTheme.bodySmall),
                          ),
                      ],
              ),
            const Divider(),
            _KeyValueSection(
              title: 'Preferences (${d.prefs.length})',
              icon: Icons.tune,
              entries: d.prefs,
            ),
            const Divider(),
            ExpansionTile(
              leading: const Icon(Icons.key_outlined),
              title: Text('Secure keystore (${d.secureKeys.length})'),
              subtitle: const Text('Values hidden — these are tokens'),
              children: [
                for (final k in d.secureKeys)
                  ListTile(
                    dense: true,
                    title: Text(k),
                    trailing: Icon(Icons.lock_outline,
                        size: 16, color: scheme.onSurfaceVariant),
                  ),
                if (d.secureKeys.isEmpty)
                  const ListTile(dense: true, title: Text('(none)')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyValueSection extends StatelessWidget {
  const _KeyValueSection({
    required this.title,
    required this.icon,
    required this.entries,
  });

  final String title;
  final IconData icon;
  final Map<String, String> entries;

  @override
  Widget build(BuildContext context) {
    final keys = entries.keys.toList()..sort();
    return ExpansionTile(
      leading: Icon(icon),
      title: Text(title),
      children: [
        for (final k in keys)
          ListTile(
            dense: true,
            title: Text(k),
            subtitle: Text(entries[k] ?? '',
                maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
        if (keys.isEmpty) const ListTile(dense: true, title: Text('(none)')),
      ],
    );
  }
}
