import 'dart:convert';

/// Severity, low to high. Compared by [index].
enum LogLevel {
  trace,
  debug,
  info,
  warn,
  error,
  fatal;

  String get label => name.toUpperCase();

  /// A glyph for quick scanning in the console.
  String get glyph => switch (this) {
        LogLevel.trace => '·',
        LogLevel.debug => '◦',
        LogLevel.info => 'ℹ',
        LogLevel.warn => '▲',
        LogLevel.error => '✖',
        LogLevel.fatal => '☠',
      };
}

/// One structured log entry. `fields` carries machine-readable context so logs
/// can be filtered/searched later, instead of everything being baked into the
/// message string.
class LogRecord {
  LogRecord({
    required this.level,
    required this.tag,
    required this.message,
    this.fields = const {},
    this.error,
    this.stackTrace,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;
  final Map<String, Object?> fields;
  final Object? error;
  final StackTrace? stackTrace;

  LogRecord copyWith({String? message, Map<String, Object?>? fields}) =>
      LogRecord(
        time: time,
        level: level,
        tag: tag,
        message: message ?? this.message,
        fields: fields ?? this.fields,
        error: error,
        stackTrace: stackTrace,
      );
}

/// Where records go. Implementations must never throw out of [add] — a logging
/// failure must not crash the app (the dispatcher also guards).
abstract class LogSink {
  void add(LogRecord record);
  Future<void> flush() async {}
  Future<void> close() async {}
}

/// Formats a record as a single human-readable line (used by console + file).
/// Multi-line error/stack is appended on following lines.
String formatLogLine(LogRecord r, {bool withGlyph = false}) {
  final b = StringBuffer()
    ..write(r.time.toIso8601String())
    ..write(' ')
    ..write(withGlyph ? r.level.glyph : r.level.label.padRight(5))
    ..write(' [')
    ..write(r.tag)
    ..write('] ')
    ..write(r.message);
  if (r.fields.isNotEmpty) {
    b.write(' ');
    b.write(jsonEncode(_encodable(r.fields)));
  }
  if (r.error != null) {
    b.write('\n    error: ');
    b.write(r.error);
  }
  if (r.stackTrace != null) {
    b.write('\n');
    b.write(r.stackTrace.toString().trimRight());
  }
  return b.toString();
}

/// Best-effort conversion of arbitrary field values to JSON-encodable ones.
Map<String, Object?> _encodable(Map<String, Object?> fields) => {
      for (final e in fields.entries)
        e.key: switch (e.value) {
          null => null,
          num n => n,
          bool b => b,
          String s => s,
          final v => v.toString(),
        },
    };
