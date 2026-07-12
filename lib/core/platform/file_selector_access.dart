import 'package:file_selector/file_selector.dart';

import 'file_system_access.dart';

/// Real [FileSystemAccess] backed by `file_selector` (works on desktop, mobile,
/// and web for *picking*). Directory watching stays unavailable here; a future
/// desktop-daemon implementation adds it. This is enough for upload: pick files
/// and expose them as lazy byte streams.
class FileSelectorAccess implements FileSystemAccess {
  const FileSelectorAccess();

  @override
  StorageModel get storage => StorageModel.pickerOnly;

  @override
  bool get canWatchDirectories => false;

  @override
  Future<List<PickedFile>> pickFiles({
    bool allowMultiple = false,
    List<String>? mimeTypes,
  }) async {
    final typeGroups = <XTypeGroup>[
      if (mimeTypes != null && mimeTypes.isNotEmpty)
        XTypeGroup(label: 'files', mimeTypes: mimeTypes),
    ];
    final files = allowMultiple
        ? await openFiles(acceptedTypeGroups: typeGroups)
        : [
            if (await openFile(acceptedTypeGroups: typeGroups)
                case final XFile file)
              file,
          ];
    return [
      for (final f in files)
        PickedFile(
          name: f.name,
          size: await f.length(),
          mimeType: f.mimeType,
          sourcePath: f.path.isEmpty ? null : f.path,
          openRead: () => f.openRead(),
        ),
    ];
  }

  @override
  Future<String?> pickDirectory() => getDirectoryPath();

  @override
  Stream<FsChange> watch(String path) => const Stream.empty();
}
