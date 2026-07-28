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
import '../../media/data/server_music.dart';
import '../../movies/data/server_movies.dart';

final _log = VaultLog.tag('upload');

/// One chunk. 16 MB balances round-trip overhead against how much work a
/// dropped connection throws away.
const _chunkBytes = 16 * 1024 * 1024;

/// How many consecutive failures one chunk may suffer before the upload is
/// reported as failed. Multi-hour transfers over a tailnet WILL hit resets;
/// giving up on the first one was the bug.
const _maxChunkRetries = 5;

/// What library an upload targets. The server uses the same two names.
enum UploadKind {
  music,
  movies;

  String get wire => name;
  String get label => this == UploadKind.music ? 'Music' : 'Movie';
}

enum UploadStatus { queued, uploading, paused, done, failed }

/// A single upload's live state.
class ContentUpload {
  const ContentUpload({
    required this.localPath,
    required this.name,
    required this.size,
    required this.kind,
    this.uploadId,
    this.sent = 0,
    this.status = UploadStatus.queued,
    this.error = '',
  });

  final String localPath;
  final String name;
  final int size;
  final UploadKind kind;

  /// Server-side id; null until the upload has been reserved.
  final String? uploadId;
  final int sent;
  final UploadStatus status;
  final String error;

  double get fraction => size == 0 ? 0 : (sent / size).clamp(0, 1);

  ContentUpload copyWith({
    String? uploadId,
    int? sent,
    UploadStatus? status,
    String? error,
  }) => ContentUpload(
    localPath: localPath,
    name: name,
    size: size,
    kind: kind,
    uploadId: uploadId ?? this.uploadId,
    sent: sent ?? this.sent,
    status: status ?? this.status,
    error: error ?? this.error,
  );

  Map<String, Object?> toJson() => {
    'path': localPath,
    'name': name,
    'size': size,
    'kind': kind.wire,
    'upload_id': uploadId,
    'sent': sent,
  };

  static ContentUpload? fromJson(Map<String, Object?> j) {
    final path = j['path'] as String?;
    if (path == null) return null;
    return ContentUpload(
      localPath: path,
      name: (j['name'] as String?) ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      kind: UploadKind.values.firstWhere(
        (k) => k.wire == j['kind'],
        // Pre-unification entries were movies-only and carry no kind.
        orElse: () => UploadKind.movies,
      ),
      uploadId: j['upload_id'] as String?,
      sent: (j['sent'] as num?)?.toInt() ?? 0,
      // Anything restored from disk starts paused — never silently resume a
      // big transfer the user didn't ask for on this launch.
      status: UploadStatus.paused,
    );
  }
}

/// The admin's content-upload queue, shared by music and movies. Chunked and
/// resumable: each chunk is its own request, the server's offset is
/// authoritative, and unfinished uploads are persisted so closing the app
/// doesn't lose a 10 GB transfer.
class ContentUploadQueue extends Notifier<List<ContentUpload>> {
  // v2: entries gained a `kind`. v1 keys are read once and migrated (they were
  // all movies), so an in-flight transfer survives the upgrade.
  static const _prefsKey = 'content_uploads_v2';
  static const _legacyKey = 'movie_uploads_v1';

  bool _pumping = false;

  @override
  List<ContentUpload> build() {
    Future.microtask(_restore);
    return const [];
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getStringList(_prefsKey) ?? const [];
    if (raw.isEmpty) {
      // Migrate the movies-only queue from before the services merged.
      final legacy = prefs.getStringList(_legacyKey) ?? const [];
      if (legacy.isNotEmpty) {
        raw = legacy;
        await prefs.remove(_legacyKey);
        _log.info('migrated legacy movie upload queue',
            fields: {'n': legacy.length});
      }
    }
    final restored = <ContentUpload>[];
    for (final s in raw) {
      try {
        final u = ContentUpload.fromJson(jsonDecode(s) as Map<String, Object?>);
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
    final pending =
        state.where((u) => u.status != UploadStatus.done && u.uploadId != null);
    await prefs.setStringList(
        _prefsKey, [for (final u in pending) jsonEncode(u.toJson())]);
  }

  void _update(String path, ContentUpload Function(ContentUpload) f) {
    state = [
      for (final u in state)
        if (u.localPath == path) f(u) else u,
    ];
  }

  /// Queue local files of [kind] and start pumping.
  Future<void> add(List<File> files, UploadKind kind) async {
    final additions = <ContentUpload>[];
    for (final f in files) {
      if (state.any((u) => u.localPath == f.path)) continue; // already queued
      additions.add(ContentUpload(
        localPath: f.path,
        name: f.path.split(Platform.pathSeparator).last,
        size: await f.length(),
        kind: kind,
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
    final match = state.where((x) => x.localPath == path);
    if (match.isEmpty) return;
    final u = match.first;
    if (u.uploadId != null) {
      try {
        await ref.read(vaultClientProvider).admin.abortUpload(u.uploadId!);
      } catch (_) {/* best effort */}
    }
    state = [
      for (final x in state)
        if (x.localPath != path) x,
    ];
    await _persist();
  }

  void clearFinished() {
    state = [
      for (final u in state)
        if (u.status != UploadStatus.done) u,
    ];
  }

  /// Adopt an upload the SERVER still holds but this device has no record of
  /// (app reinstalled, queue cleared, or it was started on another device).
  ///
  /// The caller supplies the local file to continue from. Sizes MUST match:
  /// appending a different file to an existing partial would silently produce
  /// a corrupt result, so a mismatch is refused rather than guessed at.
  Future<void> adopt(RemoteUpload remote, File local) async {
    final size = await local.length();
    if (size != remote.size) {
      throw Exception(
        'That file is ${_mb(size)} but the interrupted upload is '
        '${_mb(remote.size)} — pick the same file to continue it.',
      );
    }
    if (state.any((u) => u.uploadId == remote.id)) return; // already tracked
    state = [
      ...state,
      ContentUpload(
        localPath: local.path,
        name: remote.name,
        size: remote.size,
        kind: UploadKind.values.firstWhere((k) => k.wire == remote.kind,
            orElse: () => UploadKind.movies),
        uploadId: remote.id,
        sent: remote.offset,
      ),
    ];
    await _persist();
    unawaited(_pump());
  }

  /// Discard a server-side upload this device isn't tracking, reclaiming its
  /// staged bytes.
  Future<void> discardRemote(String uploadId) async {
    await ref.read(vaultClientProvider).admin.abortUpload(uploadId);
    ref.invalidateSelf();
  }

  static String _mb(int b) => '${(b / (1 << 20)).toStringAsFixed(1)} MB';

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

  Future<void> _run(ContentUpload upload) async {
    final api = ref.read(vaultClientProvider).admin;
    final path = upload.localPath;
    _update(path, (u) => u.copyWith(status: UploadStatus.uploading, error: ''));

    try {
      // Reserve (or reuse a restored) upload, then ALWAYS trust the server's
      // offset — it's the only thing that knows what actually landed.
      var id = upload.uploadId;
      if (id == null) {
        id = await api.beginUpload(
            kind: upload.kind.wire, name: upload.name, size: upload.size);
        _update(path, (u) => u.copyWith(uploadId: id));
        await _persist();
      }
      var offset = await api.uploadOffset(id);
      _update(path, (u) => u.copyWith(sent: offset));
      var failures = 0;

      final file = File(path);
      while (offset < upload.size) {
        // Honor a pause between chunks.
        final cur =
            state.firstWhere((u) => u.localPath == path, orElse: () => upload);
        if (cur.status == UploadStatus.paused) {
          await _persist();
          return;
        }

        final end = (offset + _chunkBytes).clamp(0, upload.size);
        final chunk = await file.openRead(offset, end).expand((b) => b).toList();

        try {
          offset = await api.uploadChunk(id, offset, chunk);
          failures = 0; // a good chunk clears the streak
          _update(path, (u) => u.copyWith(sent: offset, error: ''));
        } on UploadOffsetConflict catch (c) {
          // Server is elsewhere (a retry landed twice, or another client
          // wrote): re-sync rather than corrupt.
          _log.warn('offset conflict, resyncing',
              fields: {'ours': offset, 'server': c.serverOffset});
          offset = c.serverOffset;
          _update(path, (u) => u.copyWith(sent: offset));
        } catch (e) {
          // A dropped connection is EXPECTED on a multi-hour transfer — it
          // must cost one chunk, not the upload. Back off, then ask the
          // server where it actually is (a reset can land a partial chunk,
          // so our own offset may be stale) and carry on.
          failures++;
          if (failures > _maxChunkRetries) rethrow;
          _log.warn('chunk failed, retrying', fields: {
            'attempt': failures,
            'err': '$e',
          });
          _update(
            path,
            (u) => u.copyWith(
                error: 'Connection lost — retrying '
                    '($failures/$_maxChunkRetries)…'),
          );
          await Future<void>.delayed(Duration(seconds: 2 * failures));
          // The user may have paused or cancelled while we waited.
          final still = state.where((u) => u.localPath == path);
          if (still.isEmpty || still.first.status == UploadStatus.paused) {
            await _persist();
            return;
          }
          try {
            offset = await api.uploadOffset(id);
            _update(path, (u) => u.copyWith(sent: offset));
          } catch (_) {
            // Even the offset probe failed; the next attempt re-syncs.
          }
        }
        await _persist();
      }

      await api.finishUpload(id);
      _update(path, (u) => u.copyWith(status: UploadStatus.done, sent: u.size));
      await _persist();
      // Refresh the library this landed in. (The server also bumps the change
      // feed, so other devices update on their own.)
      switch (upload.kind) {
        case UploadKind.music:
          ref.invalidate(catalogTracksProvider);
        case UploadKind.movies:
          ref.invalidate(movieCatalogProvider);
      }
      _log.info('upload finished',
          fields: {'name': upload.name, 'kind': upload.kind.wire});
    } catch (e) {
      _log.warn('upload failed', fields: {'name': upload.name, 'err': '$e'});
      _update(
        path,
        (u) => u.copyWith(status: UploadStatus.failed, error: _humanize(e)),
      );
      await _persist();
    }
  }

  /// Turns a raw transport exception into something an admin can act on. The
  /// key reassurance: nothing already uploaded is lost — resume continues from
  /// the server's byte, not from zero.
  static String _humanize(Object e) {
    final raw = '$e';
    if (raw.contains('SocketException') ||
        raw.contains('Connection reset') ||
        raw.contains('Connection closed')) {
      return 'Connection to the server was lost. Resume to continue — '
          'the bytes already uploaded are kept.';
    }
    if (raw.contains('HTTP 401') || raw.contains('session revoked')) {
      return 'Session expired. Reconnect, then resume — progress is kept.';
    }
    if (raw.contains('HTTP 403')) {
      return 'This account is not allowed to upload content.';
    }
    if (raw.contains('HTTP 415') || raw.contains('not a')) {
      return "The server didn't accept this file type.";
    }
    return raw;
  }
}

final contentUploadQueueProvider =
    NotifierProvider<ContentUploadQueue, List<ContentUpload>>(
        ContentUploadQueue.new);

/// Uploads the SERVER is still holding staged bytes for. Fetched on demand;
/// invalidate after finishing or discarding one.
final serverUploadsProvider = FutureProvider<List<RemoteUpload>>((ref) async {
  if (!ref.watch(isAdminProvider)) return const [];
  // Re-read whenever the local queue changes, so an upload that just finished
  // stops being listed as outstanding.
  ref.watch(contentUploadQueueProvider);
  try {
    return await ref.read(vaultClientProvider).admin.pendingUploads();
  } catch (e) {
    _log.debug('could not list server uploads', fields: {'err': '$e'});
    return const [];
  }
});

/// Server-side uploads with NO local queue entry — the stranded ones. Without
/// this they'd sit on the server invisibly until the 7-day sweep: the app
/// could neither resume nor reclaim them.
final orphanUploadsProvider = Provider<List<RemoteUpload>>((ref) {
  final remote = ref.watch(serverUploadsProvider).asData?.value ?? const [];
  final localIds = {
    for (final u in ref.watch(contentUploadQueueProvider))
      if (u.uploadId != null) u.uploadId!,
  };
  return [
    for (final r in remote)
      if (!localIds.contains(r.id)) r,
  ];
});

/// Whether this device+account should see the Administrative service: a
/// connected session holding the admin-only capability. The server enforces
/// the role regardless — this only decides what to render.
final isAdminProvider = Provider<bool>((ref) {
  if (ref.watch(sessionProvider).asData?.value == null) return false;
  return ref.watch(
      canProvider((serviceId: 'admin', action: CapabilityAction.write)));
});
