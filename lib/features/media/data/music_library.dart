import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/vault_log.dart';
import '../../../core/platform/platform_info.dart';

final _log = VaultLog.tag('music');

const _audioExtensions = {
  '.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.aiff', '.alac',
};

/// A locally-stored music file.
@immutable
class MusicTrack {
  const MusicTrack({required this.id, required this.path, required this.title});

  final String id;
  final String path;

  /// Derived from the filename (metadata tag reading is a future enhancement).
  final String title;

  factory MusicTrack.fromPath(String path) {
    final name = Uri.file(path).pathSegments.last;
    final dot = name.lastIndexOf('.');
    return MusicTrack(
      id: path,
      path: path,
      title: dot > 0 ? name.substring(0, dot) : name,
    );
  }
}

/// Local music source. Persists a list of audio file paths. On desktop the user
/// picks a folder (scanned for audio); on mobile — where folder access is
/// sandboxed/unreliable — they pick audio files directly. Both append to the
/// same library.
class MusicLibrary {
  const MusicLibrary();

  static const _pathsKey = 'music_paths';

  Future<List<String>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pathsKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<String>();
  }

  Future<void> _save(List<String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pathsKey, jsonEncode(paths));
  }

  /// The stored tracks, dropping any files that no longer exist.
  Future<List<MusicTrack>> tracks() async {
    final paths = (await _load()).where((p) => File(p).existsSync()).toList();
    final tracks = paths.map(MusicTrack.fromPath).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return tracks;
  }

  /// Prompt to add music (folder on desktop, files on mobile). Returns true if
  /// anything was added.
  Future<bool> addMusic() async {
    final added = isDesktopPlatform ? await _addFolder() : await _addFiles();
    if (added.isEmpty) return false;
    final existing = await _load();
    final merged = {...existing, ...added}.toList();
    await _save(merged);
    _log.info('Added music', fields: {'added': added.length, 'total': merged.length});
    return true;
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pathsKey);
  }

  Future<List<String>> _addFiles() async {
    // FileType.custom uses the document picker (Files app). FileType.audio
    // would launch the iOS Music-library picker, which crashes without an
    // NSAppleMusicUsageDescription entry and can't pick files from iCloud
    // Drive / On My iPhone anyway.
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: [
        for (final e in _audioExtensions) e.substring(1),
      ],
    );
    return result?.files.map((f) => f.path).whereType<String>().toList() ??
        const [];
  }

  Future<List<String>> _addFolder() async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return const [];
    final directory = Directory(dir);
    if (!directory.existsSync()) return const [];
    final paths = <String>[];
    try {
      await for (final e in directory.list(recursive: true, followLinks: false)) {
        if (e is File) {
          final name = e.path.split(Platform.pathSeparator).last;
          final dot = name.lastIndexOf('.');
          final ext = dot < 0 ? '' : name.substring(dot).toLowerCase();
          if (_audioExtensions.contains(ext)) paths.add(e.path);
        }
      }
    } catch (e, s) {
      _log.error('Folder scan failed', error: e, stackTrace: s);
    }
    return paths;
  }
}

final musicLibraryProvider = Provider<MusicLibrary>((ref) => const MusicLibrary());

/// Bumped after adding music to force [musicTracksProvider] to re-read.
class MusicRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final musicRevisionProvider =
    NotifierProvider<MusicRevision, int>(MusicRevision.new);

final musicTracksProvider = FutureProvider<List<MusicTrack>>((ref) {
  ref.watch(musicRevisionProvider);
  return ref.watch(musicLibraryProvider).tracks();
});
