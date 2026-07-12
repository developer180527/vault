import 'package:flutter_riverpod/flutter_riverpod.dart';

/// List vs grid — the "View" control, now a toolbar toggle / palette command
/// instead of a menu-bar item.
enum FilesViewMode { list, grid }

class FilesViewNotifier extends Notifier<FilesViewMode> {
  @override
  FilesViewMode build() => FilesViewMode.list;

  void toggle() => state =
      state == FilesViewMode.list ? FilesViewMode.grid : FilesViewMode.list;
}

final filesViewModeProvider =
    NotifierProvider<FilesViewNotifier, FilesViewMode>(FilesViewNotifier.new);
