import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/vault_log.dart';
import 'music_library.dart';

final _log = VaultLog.tag('music.meta');

/// Parsed tags for one local track. Fields are null when the file carries no
/// tag — the UI falls back to the filename-derived title.
@immutable
class TrackMetadata {
  const TrackMetadata({this.title, this.artist, this.album, this.art});

  final String? title;
  final String? artist;
  final String? album;

  /// Embedded cover art (front cover preferred), if any.
  final Uint8List? art;
}

/// Reads tags for every path in one isolate pass — parsing is synchronous
/// file IO that would jank the UI thread done per-track on demand.
Map<String, TrackMetadata> _readAll(List<String> paths) {
  final out = <String, TrackMetadata>{};
  for (final path in paths) {
    try {
      final meta = readMetadata(File(path), getImage: true);
      final art = meta.pictures.isEmpty ? null : meta.pictures.first.bytes;
      out[path] = TrackMetadata(
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        art: art,
      );
    } catch (_) {
      // Unsupported container or corrupt tag — the UI falls back gracefully.
      out[path] = const TrackMetadata();
    }
  }
  return out;
}

/// Tags for the whole library, keyed by file path. Re-reads when the library
/// changes (musicRevisionProvider bump). Kept in memory: art for a personal
/// library is a few MB at most, and reads are local-disk fast.
final musicMetadataProvider =
    FutureProvider<Map<String, TrackMetadata>>((ref) async {
  final tracks = await ref.watch(musicTracksProvider.future);
  if (tracks.isEmpty) return const {};
  final paths = [for (final t in tracks) t.path];
  final result = await compute(_readAll, paths);
  _log.info('Read tags', fields: {
    'tracks': result.length,
    'withArt': result.values.where((m) => m.art != null).length,
  });
  return result;
});

/// Convenience: metadata for a single path from the batch map (empty default
/// while loading).
TrackMetadata metadataFor(WidgetRef ref, String path) =>
    ref.watch(musicMetadataProvider).asData?.value[path] ??
    const TrackMetadata();
