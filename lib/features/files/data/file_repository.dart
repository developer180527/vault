import 'file_node.dart';

/// Read side of the file browser. Backed later by the drift mirror that the
/// sync engine keeps current from the server journal; for now a mock provides
/// a believable tree so the UI can be built and verified. The UI always reads
/// through this — never the server directly.
abstract interface class FileRepository {
  /// Direct children of [parentId] (null = the My Files root), already sorted
  /// (folders first, then name). Reads from the local mirror, so it's instant
  /// and works offline.
  Future<List<FileNode>> children(String? parentId);

  /// A node by id, for breadcrumb/detail.
  Future<FileNode?> node(String id);

  /// The chain from the root down to [id], for the breadcrumb.
  Future<List<FileNode>> pathTo(String id);

  // --- Mutations (increment 2). Applied optimistically to the mirror; the real
  // repository will also enqueue a server job and reconcile from the journal.

  /// Create a folder under [parentId]. Returns its id.
  Future<String> createFolder(String? parentId, String name);

  /// Register a picked local file as a pending upload (localOnly) node.
  Future<String> addLocalFile(String? parentId, String name,
      {int? size, FileMediaKind mediaKind = FileMediaKind.none});

  Future<void> rename(String id, String newName);

  Future<void> setPinned(String id, bool pinned);

  /// Soft-delete → trash (never destroys).
  Future<void> trash(String id);
}

/// In-memory tree standing in for the synced mirror. Models the files-on-demand
/// world: most nodes are `remoteOnly`, some are `available`/`pinned`, a couple
/// are mid-transfer or shared — so every badge state is exercised.
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
  Future<String> addLocalFile(String? parentId, String name,
      {int? size, FileMediaKind mediaKind = FileMediaKind.none}) async {
    final id = _newId('file');
    _add(FileNode(
      id: id,
      parentId: parentId,
      name: name,
      kind: NodeKind.file,
      mediaKind: mediaKind,
      size: size,
      syncStatus: SyncStatus.localOnly, // pending upload
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
