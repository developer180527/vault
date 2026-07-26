import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/session.dart';
import '../../../core/capability/capability.dart';
import '../../../core/capability/manifest_providers.dart';
import '../../../core/client/vault_client.dart';
import '../../../core/logging/vault_log.dart';
import '../../../core/platform/platform_info.dart';
import 'server_movies.dart';

final _log = VaultLog.tag('movieupload');

/// One chunk. 16 MB balances round-trip overhead against how much work a
/// dropped connection throws away.
const _chunkBytes = 16 * 1024 * 1024;

enum UploadStatus { queued, uploading, paused, done, failed }

/// A single movie upload's live state.
class MovieUpload {
  const MovieUpload({
    required this.localPath,
    required this.name,
    required this.size,
    this.uploadId,
    this.sent = 0,
    this.status = UploadStatus.queued,
    this.error = '',
  });

  final String localPath;
  final String name;
  final int size;

  /// Server-side id; null until the upload has been reserved.
  final String? uploadId;
  final int sent;
  final UploadStatus status;
  final String error;

  double get fraction => size == 0 ? 0 : (sent / size).clamp(0, 1);

  MovieUpload copyWith({
    String? uploadId,
    int? sent,
    UploadStatus? status,
    String? error,
  }) => MovieUpload(
    localPath: localPath,
    name: name,
    size: size,
    uploadId: uploadId ?? this.uploadId,
    sent: sent ?? this.sent,
    status: status ?? this.status,
    error: error ?? this.error,
  );

  Map<String, Object?> toJson() => {
    'path': localPath,
    'name': name,
    'size': size,
    'upload_id': uploadId,
    'sent': sent,
  };

  static MovieUpload? fromJson(Map<String, Object?> j) {
    final path = j['path'] as String?;
    if (path == null) return null;
    return MovieUpload(
      localPath: path,
      name: (j['name'] as String?) ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      uploadId: j['upload_id'] as String?,
      sent: (j['sent'] as num?)?.toInt() ?? 0,
      // Anything restored from disk starts paused — never silently resume a
      // big transfer the user didn't ask for on this launch.
      status: UploadStatus.paused,
    );
  }
}

/// The admin's movie-upload queue. Chunked and resumable: each chunk is its
/// own request, the server's offset is authoritative, and unfinished uploads
/// are persisted so closing the app doesn't lose a 10 GB transfer.
class MovieUploadQueue extends Notifier<List<MovieUpload>> {
  static const _prefsKey = 'movie_uploads_v1';

  bool _pumping = false;

  @override
  List<MovieUpload> build() {
    // Restore unfinished uploads (paused) on first read.
    Future.microtask(_restore);
    return const [];
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    final restored = <MovieUpload>[];
    for (final s in raw) {
      try {
        final u = MovieUpload.fromJson(jsonDecode(s) as Map<String, Object?>);
        // Drop entries whose source file is gone — nothing to resume from.
        if (u != null && await File(u.localPath).exists()) restored.add(u);
      } catch (_) {/* skip corrupt entry */}
    }
    if (restored.isNotEmpty) {
      state = [...state, ...restored];
      _log.info('restored unfinished uploads', fields: {'n': restored.length});
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    // Only unfinished work is worth restoring.
    final pending = state.where((u) =>
        u.status != UploadStatus.done && u.uploadId != null);
    await prefs.setStringList(
        _prefsKey, [for (final u in pending) jsonEncode(u.toJson())]);
  }

  void _update(String path, MovieUpload Function(MovieUpload) f) {
    state = [
      for (final u in state) if (u.localPath == path) f(u) else u,
    ];
  }

  /// Queue local files for upload and start pumping.
  Future<void> add(List<File> files) async {
    final additions = <MovieUpload>[];
    for (final f in files) {
      if (state.any((u) => u.localPath == f.path)) continue; // already queued
      additions.add(MovieUpload(
        localPath: f.path,
        name: f.path.split(Platform.pathSeparator).last,
        size: await f.length(),
      ));
    }
    if (additions.isEmpty) return;
    state = [...state, ...additions];
    unawaited(_pump());
  }

  void pause(String path) =>
      _update(path, (u) => u.copyWith(status: UploadStatus.paused));

  void resume(String path) {
    _update(path, (u) => u.copyWith(status: UploadStatus.queued, error: ''));
    unawaited(_pump());
  }

  /// Remove from the queue; abandons the server-side upload too.
  Future<void> cancel(String path) async {
    final u = state.firstWhere((x) => x.localPath == path,
        orElse: () => const MovieUpload(localPath: '', name: '', size: 0));
    if (u.uploadId != null) {
      try {
        await ref.read(vaultClientProvider).movies.abortUpload(u.uploadId!);
      } catch (_) {/* best effort */}
    }
    state = [for (final x in state) if (x.localPath != path) x];
    await _persist();
  }

  void clearFinished() {
    state = [for (final u in state) if (u.status != UploadStatus.done) u];
  }

  /// Drive the queue one file at a time — a 10 GB upload should own the
  /// uplink, not compete with three others.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final next = state.where((u) => u.status == UploadStatus.queued);
        if (next.isEmpty) break;
        await _run(next.first);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(MovieUpload upload) async {
    final api = ref.read(vaultClientProvider).movies;
    final path = upload.localPath;
    _update(path, (u) => u.copyWith(status: UploadStatus.uploading, error: ''));

    try {
      // Reserve (or reuse a restored) upload, then ALWAYS trust the server's
      // offset — it's the only thing that knows what actually landed.
      var id = upload.uploadId;
      if (id == null) {
        id = await api.beginUpload(name: upload.name, size: upload.size);
        _update(path, (u) => u.copyWith(uploadId: id));
        await _persist();
      }
      var offset = await api.uploadOffset(id);
      _update(path, (u) => u.copyWith(sent: offset));

      final file = File(path);
      while (offset < upload.size) {
        // Honor a pause between chunks.
        final cur = state.firstWhere((u) => u.localPath == path,
            orElse: () => upload);
        if (cur.status == UploadStatus.paused) {
          await _persist();
          return;
        }

        final end = (offset + _chunkBytes).clamp(0, upload.size);
        final chunk =
            await file.openRead(offset, end).expand((b) => b).toList();

        try {
          offset = await api.uploadChunk(id, offset, chunk);
        } on UploadOffsetConflict catch (c) {
          // Server is elsewhere (a retry landed twice, or another client
          // wrote): re-sync rather than corrupt.
          _log.warn('offset conflict, resyncing',
              fields: {'ours': offset, 'server': c.serverOffset});
          offset = c.serverOffset;
        }
        _update(path, (u) => u.copyWith(sent: offset));
        await _persist();
      }

      await api.finishUpload(id);
      _update(path, (u) => u.copyWith(status: UploadStatus.done, sent: u.size));
      await _persist();
      ref.invalidate(movieCatalogProvider);
      _log.info('movie uploaded', fields: {'name': upload.name});
    } catch (e) {
      _log.warn('upload failed', fields: {'name': upload.name, 'err': '$e'});
      _update(path,
          (u) => u.copyWith(status: UploadStatus.failed, error: '$e'));
      await _persist();
    }
  }
}

final movieUploadQueueProvider =
    NotifierProvider<MovieUploadQueue, List<MovieUpload>>(
        MovieUploadQueue.new);

/// Whether this device+account should see the uploader: desktop only (nobody
/// pushes 12 GB from a phone) AND holding movies:write (admin).
final canUploadMoviesProvider = Provider<bool>((ref) {
  if (!isDesktopPlatform) return false;
  if (ref.watch(sessionProvider).asData?.value == null) return false;
  return ref.watch(canProvider(
      (serviceId: 'movies', action: CapabilityAction.write)));
});
