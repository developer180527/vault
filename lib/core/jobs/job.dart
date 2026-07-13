import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter/foundation.dart';

/// What kind of work a job does. Torrent and URL downloads run ON THE SERVER
/// (the client only submits and observes); uploads are client-side work
/// tracked through the same pipeline so the UI treats all background work
/// uniformly.
enum JobKind {
  torrent('Torrent', Icons.swap_vert_circle_outlined),
  download('Download', Icons.download_outlined), // yt-dlp style URL fetch
  upload('Upload', Icons.upload_outlined);

  const JobKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

enum JobState {
  queued('Queued'),
  running('Running'),
  completed('Completed'),
  failed('Failed'),
  canceled('Canceled');

  const JobState(this.label);
  final String label;

  /// Finished states can be cleared from the list and retried (except
  /// completed, which only clears).
  bool get isFinished =>
      this == completed || this == failed || this == canceled;
}

/// A unit of background work, as reported by the server (or simulated by the
/// mock client). Immutable snapshot; the jobs stream emits new lists as state
/// advances.
@immutable
class VaultJob {
  const VaultJob({
    required this.id,
    required this.kind,
    required this.title,
    required this.source,
    required this.createdAt,
    this.state = JobState.queued,
    this.progress = 0,
    this.message,
  });

  final String id;
  final JobKind kind;

  /// Human-readable name (torrent display name, filename, URL tail).
  final String title;

  /// What was submitted: magnet link, URL, or local path.
  final String source;
  final DateTime createdAt;
  final JobState state;

  /// 0..1. Meaningful while running; 1.0 when completed.
  final double progress;

  /// Status detail or failure reason.
  final String? message;

  VaultJob copyWith({
    JobState? state,
    double? progress,
    String? message,
  }) =>
      VaultJob(
        id: id,
        kind: kind,
        title: title,
        source: source,
        createdAt: createdAt,
        state: state ?? this.state,
        progress: progress ?? this.progress,
        message: message ?? this.message,
      );
}

/// A submission. The kind is inferred by the caller (magnet: → torrent,
/// http(s) → download, local path → upload).
@immutable
class JobRequest {
  const JobRequest({required this.kind, required this.source, this.title});

  final JobKind kind;
  final String source;

  /// Optional display name; derived from [source] when omitted.
  final String? title;
}
