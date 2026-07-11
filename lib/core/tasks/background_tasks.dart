import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A unit of background work surfaced in the shell (title-bar button on
/// desktop, app-bar icon on mobile). The sync/transfer engine will feed this;
/// for now Settings can inject demo tasks.
class BackgroundTask {
  const BackgroundTask({
    required this.id,
    required this.label,
    this.progress,
  });

  final String id;
  final String label;

  /// 0..1, or null for indeterminate work.
  final double? progress;
}

class BackgroundTasksNotifier extends Notifier<List<BackgroundTask>> {
  @override
  List<BackgroundTask> build() => const [];

  void upsert(BackgroundTask task) {
    state = [
      for (final t in state)
        if (t.id != task.id) t,
      task,
    ];
  }

  void remove(String id) {
    state = [
      for (final t in state)
        if (t.id != id) t,
    ];
  }

  void clear() => state = const [];
}

final backgroundTasksProvider =
    NotifierProvider<BackgroundTasksNotifier, List<BackgroundTask>>(
        BackgroundTasksNotifier.new);
