import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../capability/capability.dart';
import '../capability/manifest_source.dart';
import '../jobs/job.dart';
import '../logging/vault_log.dart';
import '../models/file_node.dart';
import 'vault_client.dart';

final _log = VaultLog.tag('client.mock');

/// Stand-in Vault server: an in-memory file tree and an in-process job
/// scheduler with believable timing. Lets every feature be built and demoed
/// against the real [VaultClient] contract before vaultd exists.
class MockVaultClient implements VaultClient {
  MockVaultClient({
    required this.serviceIds,
    Duration jobTick = const Duration(milliseconds: 400),
    int maxConcurrentJobs = 2,
  })  : files = MockFileRepository(),
        _jobs = _MockJobScheduler(tick: jobTick, maxConcurrent: maxConcurrentJobs);

  /// Deferred so constructing the client never touches other providers.
  final List<String> Function() serviceIds;

  @override
  final MockFileRepository files;

  final _MockJobScheduler _jobs;

  @override
  VaultJobsApi get jobs => _jobs;

  /// Standalone mode plays LOCAL files (a device feature); the server music
  /// API has no mock — reaching this is a wiring bug, so fail loudly.
  @override
  MusicApi get music =>
      throw UnsupportedError('server music requires a connected session');

  /// Backup targets a server by definition; standalone has nowhere to send.
  @override
  PhotosApi get photos =>
      throw UnsupportedError('photo backup requires a connected session');

  @override
  MoviesApi get movies =>
      throw UnsupportedError('server movies require a connected session');

  @override
  SyncApi get sync =>
      throw UnsupportedError('folder sync requires a connected session');

  // Standalone devices have no server-side profile.
  @override
  Future<Uint8List?> myAvatar() async => null;

  @override
  Future<void> setMyAvatar(Uint8List bytes) async {}

  @override
  Future<CapabilityManifest> fetchManifest() async =>
      MockManifestSource.fullGrant(serviceIds());

  @override
  void dispose() => _jobs.dispose();
}

/// In-process job scheduler simulating the server's. Jobs are queued on
/// submit and started automatically as slots free up (max [maxConcurrent]
/// running); progress ticks until completion. A source containing the word
/// "fail" fails partway — handy for exercising the retry path in dev/tests.
class _MockJobScheduler implements VaultJobsApi {
  _MockJobScheduler({required this.tick, required this.maxConcurrent});

  final Duration tick;
  final int maxConcurrent;

  final _jobs = <String, VaultJob>{};
  final _timers = <String, Timer>{};
  final _changes = StreamController<List<VaultJob>>.broadcast();
  final _random = math.Random();
  int _seq = 0;
  bool _disposed = false;

  List<VaultJob> _snapshot() {
    final list = _jobs.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  void _emit() {
    if (!_disposed) _changes.add(_snapshot());
  }

  @override
  Stream<List<VaultJob>> watch() async* {
    yield _snapshot();
    yield* _changes.stream;
  }

  @override
  Future<VaultJob> submit(JobRequest request) async {
    final job = VaultJob(
      id: 'job-${_seq++}',
      kind: request.kind,
      title: request.title ?? _titleFor(request.source),
      source: request.source,
      createdAt: DateTime.now(),
    );
    _jobs[job.id] = job;
    _log.info('Job submitted',
        fields: {'id': job.id, 'kind': job.kind.name, 'title': job.title});
    _emit();
    _schedule();
    return job;
  }

  @override
  Future<void> cancel(String id) async {
    final job = _jobs[id];
    if (job == null || job.state.isFinished) return;
    _timers.remove(id)?.cancel();
    _jobs[id] = job.copyWith(state: JobState.canceled);
    _emit();
    _schedule(); // the freed slot may start a queued job
  }

  @override
  Future<void> retry(String id) async {
    final job = _jobs[id];
    if (job == null ||
        (job.state != JobState.failed && job.state != JobState.canceled)) {
      return;
    }
    _jobs[id] = job.copyWith(state: JobState.queued, progress: 0, message: null);
    _emit();
    _schedule();
  }

  @override
  Future<void> clearFinished() async {
    _jobs.removeWhere((_, j) => j.state.isFinished);
    _emit();
  }

  /// The scheduler core: fill free slots with queued jobs, oldest first.
  void _schedule() {
    if (_disposed) return;
    var running = _jobs.values.where((j) => j.state == JobState.running).length;
    final queued = _jobs.values.where((j) => j.state == JobState.queued).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final job in queued) {
      if (running >= maxConcurrent) break;
      _start(job.id);
      running++;
    }
  }

  void _start(String id) {
    _jobs[id] = _jobs[id]!.copyWith(state: JobState.running);
    _emit();
    _timers[id] = Timer.periodic(tick, (_) => _tick(id));
  }

  void _tick(String id) {
    final job = _jobs[id];
    if (job == null || job.state != JobState.running) {
      _timers.remove(id)?.cancel();
      return;
    }
    final progress = job.progress + 0.05 + _random.nextDouble() * 0.1;

    // Deterministic failure hook for dev/tests.
    if (job.source.contains('fail') && progress > 0.4) {
      _timers.remove(id)?.cancel();
      _jobs[id] = job.copyWith(
          state: JobState.failed, message: 'Simulated failure (mock server)');
      _emit();
      _schedule();
      return;
    }

    if (progress >= 1) {
      _timers.remove(id)?.cancel();
      _jobs[id] = job.copyWith(state: JobState.completed, progress: 1);
      _log.info('Job completed', fields: {'id': id, 'title': job.title});
      _emit();
      _schedule();
      return;
    }

    _jobs[id] = job.copyWith(progress: progress);
    _emit();
  }

  String _titleFor(String source) {
    // magnet:?xt=...&dn=<display name>
    final dn = Uri.tryParse(source)?.queryParameters['dn'];
    if (dn != null && dn.isNotEmpty) return dn;
    final tail = Uri.tryParse(source)?.pathSegments.lastOrNull;
    if (tail != null && tail.isNotEmpty) return tail;
    return source;
  }

  void dispose() {
    _disposed = true;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _changes.close();
  }
}

/// In-memory tree standing in for the synced mirror. Models the
/// files-on-demand world: most nodes are `remoteOnly`, some are
/// `available`/`pinned`, a couple are mid-transfer or shared — so every badge
/// state is exercised.
class MockFileRepository implements FileRepository {
  MockFileRepository() {
    _seed();
  }

  final Map<String, FileNode> _byId = {};
  final Map<String?, List<String>> _childIds = {};

  void _add(FileNode node) {
    _byId[node.id] = node;
    _childIds.putIfAbsent(node.parentId, () => []).add(node.id);
  }

  void _seed() {
    _add(const FileNode(
        id: 'documents',
        parentId: null,
        name: 'Documents',
        kind: NodeKind.folder,
        childCount: 3,
        syncStatus: SyncStatus.available));
    _add(const FileNode(
        id: 'photos',
        parentId: null,
        name: 'Photos',
        kind: NodeKind.folder,
        childCount: 2,
        shareStatus: ShareStatus.sharedByMe,
        syncStatus: SyncStatus.available));
    _add(const FileNode(
        id: 'movies',
        parentId: null,
        name: 'Movies',
        kind: NodeKind.folder,
        childCount: 2,
        syncStatus: SyncStatus.remoteOnly));
    _add(FileNode(
        id: 'taxes.pdf',
        parentId: null,
        name: 'Tax Return 2025.pdf',
        kind: NodeKind.file,
        mediaKind: FileMediaKind.document,
        size: 2_400_000,
        pinned: true,
        syncStatus: SyncStatus.available,
        modifiedAt: DateTime(2026, 4, 12)));
    _add(FileNode(
        id: 'backup.zip',
        parentId: null,
        name: 'server-backup.zip',
        kind: NodeKind.file,
        size: 8_900_000_000,
        syncStatus: SyncStatus.remoteOnly,
        modifiedAt: DateTime(2026, 7, 1)));

    // Documents/
    _add(FileNode(
        id: 'resume.pdf',
        parentId: 'documents',
        name: 'Resume.pdf',
        kind: NodeKind.file,
        mediaKind: FileMediaKind.document,
        size: 180_000,
        syncStatus: SyncStatus.available,
        modifiedAt: DateTime(2026, 2, 3)));
    _add(FileNode(
        id: 'notes.md',
        parentId: 'documents',
        name: 'notes.md',
        kind: NodeKind.file,
        mediaKind: FileMediaKind.document,
        size: 4200,
        syncStatus: SyncStatus.localOnly,
        modifiedAt: DateTime(2026, 7, 12)));
    _add(FileNode(
        id: 'contract.pdf',
        parentId: 'documents',
        name: 'contract-final.pdf',
        kind: NodeKind.file,
        mediaKind: FileMediaKind.document,
        size: 640_000,
        shareStatus: ShareStatus.sharedWithMe,
        syncStatus: SyncStatus.remoteOnly,
        modifiedAt: DateTime(2026, 6, 20)));

    // Photos/
    _add(FileNode(
        id: 'trip.jpg',
        parentId: 'photos',
        name: 'trip.jpg',
        kind: NodeKind.file,
        mediaKind: FileMediaKind.image,
        size: 3_100_000,
        syncStatus: SyncStatus.uploading,
        modifiedAt: DateTime(2026, 7, 11)));
    _add(FileNode(
        id: 'family.jpg',
        parentId: 'photos',
        name: 'family.jpg',
        kind: NodeKind.file,
        mediaKind: FileMediaKind.image,
        size: 2_700_000,
        pinned: true,
        syncStatus: SyncStatus.available,
        modifiedAt: DateTime(2026, 5, 9)));

    // Movies/
    _add(FileNode(
        id: 'holiday.mkv',
        parentId: 'movies',
        name: 'holiday-2025.mkv',
        kind: NodeKind.file,
        mediaKind: FileMediaKind.video,
        size: 4_200_000_000,
        syncStatus: SyncStatus.downloading,
        modifiedAt: DateTime(2025, 12, 30)));
    _add(FileNode(
        id: 'concert.mp4',
        parentId: 'movies',
        name: 'concert.mp4',
        kind: NodeKind.file,
        mediaKind: FileMediaKind.video,
        size: 1_800_000_000,
        isConflicted: true,
        syncStatus: SyncStatus.failed,
        modifiedAt: DateTime(2026, 3, 15)));
  }

  @override
  Future<List<FileNode>> children(String? parentId) async {
    final ids = _childIds[parentId] ?? const [];
    final nodes = [for (final id in ids) _byId[id]!];
    nodes.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return nodes;
  }

  int _seq = 0;
  String _newId(String base) => '$base-${_seq++}';

  @override
  Future<String> createFolder(String? parentId, String name) async {
    final id = _newId('folder');
    _add(FileNode(
      id: id,
      parentId: parentId,
      name: name,
      kind: NodeKind.folder,
      childCount: 0,
      syncStatus: SyncStatus.localOnly,
      modifiedAt: DateTime.now(),
    ));
    _bumpChildCount(parentId, 1);
    return id;
  }

  @override
  Future<String> uploadFile(
      String? parentId, String name, Stream<List<int>> bytes, int length,
      {FileMediaKind mediaKind = FileMediaKind.none}) async {
    // Drain the stream so the byte count is real, then land an available node.
    await bytes.drain<void>();
    final id = _newId('file');
    _add(FileNode(
      id: id,
      parentId: parentId,
      name: name,
      kind: NodeKind.file,
      mediaKind: mediaKind,
      size: length,
      syncStatus: SyncStatus.available,
      modifiedAt: DateTime.now(),
    ));
    _bumpChildCount(parentId, 1);
    return id;
  }

  @override
  Future<void> rename(String id, String newName) async {
    final n = _byId[id];
    if (n == null) return;
    _byId[id] = n.copyWith(name: newName, modifiedAt: DateTime.now());
  }

  @override
  bool get supportsPinning => true;

  @override
  Future<void> setPinned(String id, bool pinned) async {
    final n = _byId[id];
    if (n == null) return;
    _byId[id] = n.copyWith(
      pinned: pinned,
      // Pinning a remote-only file implies it becomes available locally.
      syncStatus: pinned && n.syncStatus == SyncStatus.remoteOnly
          ? SyncStatus.available
          : n.syncStatus,
    );
  }

  @override
  Future<void> trash(String id) async {
    final n = _byId[id];
    if (n == null) return;
    _childIds[n.parentId]?.remove(id);
    _byId.remove(id);
    _bumpChildCount(n.parentId, -1);
  }

  void _bumpChildCount(String? parentId, int delta) {
    if (parentId == null) return;
    final p = _byId[parentId];
    if (p == null) return;
    _byId[parentId] = p.copyWith(childCount: (p.childCount ?? 0) + delta);
  }

  @override
  Future<FileNode?> node(String id) async => _byId[id];

  @override
  Future<List<FileNode>> pathTo(String id) async {
    final chain = <FileNode>[];
    String? cursor = id;
    while (cursor != null) {
      final n = _byId[cursor];
      if (n == null) break;
      chain.insert(0, n);
      cursor = n.parentId;
    }
    return chain;
  }
}
