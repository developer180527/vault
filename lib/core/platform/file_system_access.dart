import 'dart:async';

/// How much of the local filesystem this host exposes — the seam between a
/// desktop with free-roaming access + folder watchers and a sandboxed mobile
/// OS. Business logic reads [FileSystemAccess.storage] to decide, e.g., whether
/// continuous folder auto-backup is even possible here.
enum StorageModel {
  /// Desktop: arbitrary paths, real directory watching.
  fullFileSystem,

  /// Mobile: scoped/permissioned access (photo library, Storage Access
  /// Framework); watching is limited to what the OS surfaces.
  scopedStorage,

  /// Web: no ambient filesystem — only what the user hands us via a picker.
  pickerOnly,
}

enum FsChangeType { created, modified, deleted }

class FsChange {
  const FsChange({required this.path, required this.type});
  final String path;
  final FsChangeType type;
}

/// A file the user selected, exposed as a lazy byte stream so large media can
/// be chunk-uploaded without loading into memory. [sourcePath] is null on hosts
/// (web) that don't expose real paths.
class PickedFile {
  const PickedFile({
    required this.name,
    required this.size,
    required this.openRead,
    this.mimeType,
    this.sourcePath,
  });

  final String name;
  final int size;
  final String? mimeType;
  final String? sourcePath;
  final Stream<List<int>> Function() openRead;
}

/// Port for local file selection, saving, and (where supported) directory
/// watching used by auto-backup. Implementations: `DesktopFs` (dart:io + a
/// watcher), `MobileFs` (photo library + document picker), `WebFs` (input).
abstract interface class FileSystemAccess {
  StorageModel get storage;

  /// True where continuous directory watching is available (desktop). When
  /// false, auto-backup must fall back to OS media-change hooks or manual scans.
  bool get canWatchDirectories;

  Future<List<PickedFile>> pickFiles({
    bool allowMultiple = false,
    List<String>? mimeTypes,
  });

  /// Returns a directory identifier/path, or null if cancelled/unsupported.
  Future<String?> pickDirectory();

  /// Emits changes under [path]. Empty stream where [canWatchDirectories] is
  /// false, so callers can subscribe unconditionally.
  Stream<FsChange> watch(String path);
}

/// Default until host implementations land: reports the most restrictive model
/// and returns nothing, so callers wire up safely.
class StubFileSystemAccess implements FileSystemAccess {
  const StubFileSystemAccess();

  @override
  StorageModel get storage => StorageModel.pickerOnly;

  @override
  bool get canWatchDirectories => false;

  @override
  Future<List<PickedFile>> pickFiles({
    bool allowMultiple = false,
    List<String>? mimeTypes,
  }) async =>
      const [];

  @override
  Future<String?> pickDirectory() async => null;

  @override
  Stream<FsChange> watch(String path) => const Stream.empty();
}
