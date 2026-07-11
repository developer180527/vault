import 'dart:async';

/// Durability of background work — the axis on which hosts differ most, and the
/// reason this port exists. Shared business logic reads [BackgroundRunner.model]
/// to decide *how much* to lean on background execution (e.g. whether to run a
/// full library index opportunistically or only while the user waits).
enum BackgroundModel {
  /// Web / plain foreground apps: work runs only while the app is visible.
  foregroundOnly,

  /// Mobile: the OS grants periodic/opportunistic windows (Android WorkManager,
  /// iOS BGTaskScheduler). Bounded, not guaranteed-immediate.
  osScheduled,

  /// Desktop daemon: a resident process runs work continuously, even with no
  /// window open.
  persistentDaemon,
}

enum JobKind { upload, download, mediaIndex, transcodeWarm, sync }

enum JobStatus { queued, running, succeeded, failed, cancelled }

/// A unit of durable background work. Kept host-agnostic: the concrete runner
/// maps these onto WorkManager/BGTask/daemon queues.
class BackgroundJobSpec {
  const BackgroundJobSpec({
    required this.id,
    required this.kind,
    this.args = const {},
    this.requiresNetwork = true,
    this.requiresUnmetered = false,
    this.requiresCharging = false,
  });

  final String id;
  final JobKind kind;
  final Map<String, Object?> args;
  final bool requiresNetwork;
  final bool requiresUnmetered;
  final bool requiresCharging;
}

class BackgroundJobEvent {
  const BackgroundJobEvent({
    required this.id,
    required this.status,
    this.progress,
    this.message,
  });

  final String id;
  final JobStatus status;

  /// 0..1, or null for indeterminate.
  final double? progress;
  final String? message;
}

/// Port for scheduling durable background work (uploads, sync, media indexing,
/// transcode warm-ups). Implementations: `WorkManagerRunner` (Android),
/// `BgTaskRunner` (iOS), `DaemonRunner` (desktop, talks to the resident
/// process), and the foreground [StubBackgroundRunner] default.
abstract interface class BackgroundRunner {
  BackgroundModel get model;

  Future<void> enqueue(BackgroundJobSpec spec);

  Future<void> cancel(String jobId);

  /// Progress/lifecycle stream. The shell's task-status UI subscribes here.
  Stream<BackgroundJobEvent> events();
}

/// Default until real host runners land: runs nothing durable, just echoes a
/// queued→cancelled lifecycle so callers can wire up without crashing. Honest
/// about its limits via [model].
class StubBackgroundRunner implements BackgroundRunner {
  StubBackgroundRunner();

  final _controller = StreamController<BackgroundJobEvent>.broadcast();

  @override
  BackgroundModel get model => BackgroundModel.foregroundOnly;

  @override
  Future<void> enqueue(BackgroundJobSpec spec) async {
    _controller.add(BackgroundJobEvent(id: spec.id, status: JobStatus.queued));
  }

  @override
  Future<void> cancel(String jobId) async {
    _controller.add(
        BackgroundJobEvent(id: jobId, status: JobStatus.cancelled));
  }

  @override
  Stream<BackgroundJobEvent> events() => _controller.stream;

  void dispose() => _controller.close();
}
