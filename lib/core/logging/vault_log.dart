import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'log_types.dart';
import 'redactor.dart';
import 'sinks/console_sink.dart';
import 'sinks/file_sink.dart';
import 'sinks/memory_sink.dart';

/// Central logging facade. Usage:
///
/// ```dart
/// final _log = VaultLog.tag('sync');
/// _log.info('journal caught up', fields: {'entries': 42});
/// _log.error('upload failed', error: e, stackTrace: s);
/// ```
///
/// Records below [minLevel] are dropped before any work. Everything else is
/// redacted once, then fanned out to the configured sinks (console in debug,
/// a rotating file for persistence, and an in-memory ring for the viewer).
class VaultLog {
  VaultLog._();

  /// Verbose in debug, quieter in release (still captures info+ to file).
  static LogLevel minLevel =
      kReleaseMode ? LogLevel.info : LogLevel.trace;

  static const _redactor = Redactor();
  static final List<LogSink> _sinks = [];

  /// The in-app-viewer buffer, available once [init] has run.
  static MemoryLogSink? memory;

  static bool _initialized = false;

  static VaultLogger tag(String tag) => VaultLogger._(tag);

  /// Sets up sinks. Safe to call once, early in `main`. Pass [sinks] to
  /// override (tests use this).
  static Future<void> init({List<LogSink>? sinks}) async {
    if (_initialized) return;
    _initialized = true;

    if (sinks != null) {
      _sinks.addAll(sinks);
      return;
    }

    memory = MemoryLogSink();
    _sinks.add(memory!);

    if (!kReleaseMode) _sinks.add(ConsoleLogSink());

    if (!kIsWeb) {
      try {
        final base = await getApplicationSupportDirectory();
        final fileSink = FileLogSink('${base.path}/logs');
        await fileSink.open();
        _sinks.add(fileSink);
      } catch (e) {
        // File logging unavailable (e.g. sandbox denial); keep going.
        tag('log').warn('File logging unavailable', error: e);
      }
    }

    tag('app').info('Logger initialized', fields: {
      'release': kReleaseMode,
      'platform': kIsWeb ? 'web' : Platform.operatingSystem,
      'sinks': _sinks.length,
    });
  }

  /// Routes uncaught framework/platform errors into the log. Pair with a
  /// `runZonedGuarded` in `main` for async errors.
  static void installErrorHandlers() {
    final prior = FlutterError.onError;
    FlutterError.onError = (details) {
      tag('flutter').error(
        details.summary.toString(),
        error: details.exception,
        stackTrace: details.stack,
        fields: {'library': details.library ?? 'unknown'},
      );
      prior?.call(details); // keep default (red screen in debug, etc.)
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      tag('platform').fatal('Uncaught platform error',
          error: error, stackTrace: stack);
      return true;
    };
  }

  static void dispatch(LogRecord record) {
    if (record.level.index < minLevel.index) return;
    final redacted = _redactor.record(record);
    for (final sink in _sinks) {
      try {
        sink.add(redacted);
      } catch (_) {
        // A broken sink must never break logging or the app.
      }
    }
  }

  static Future<void> flush() async {
    for (final sink in _sinks) {
      await sink.flush();
    }
  }

  @visibleForTesting
  static void reset() {
    _sinks.clear();
    memory = null;
    _initialized = false;
    minLevel = kReleaseMode ? LogLevel.info : LogLevel.trace;
  }
}

/// A logger bound to a subsystem [tag] (e.g. 'sync', 'files', 'media'). Obtain
/// one per file: `final _log = VaultLog.tag('files');`.
class VaultLogger {
  const VaultLogger._(this.tag);

  final String tag;

  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) {
    // Cheap early-out so disabled levels cost almost nothing.
    if (level.index < VaultLog.minLevel.index) return;
    VaultLog.dispatch(LogRecord(
      level: level,
      tag: tag,
      message: message,
      fields: fields,
      error: error,
      stackTrace: stackTrace,
    ));
  }

  void trace(String m, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.trace, m, fields: fields);
  void debug(String m, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.debug, m, fields: fields);
  void info(String m, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.info, m, fields: fields);
  void warn(String m,
          {Map<String, Object?> fields = const {}, Object? error}) =>
      log(LogLevel.warn, m, fields: fields, error: error);
  void error(String m,
          {Map<String, Object?> fields = const {},
          Object? error,
          StackTrace? stackTrace}) =>
      log(LogLevel.error, m,
          fields: fields, error: error, stackTrace: stackTrace);
  void fatal(String m,
          {Map<String, Object?> fields = const {},
          Object? error,
          StackTrace? stackTrace}) =>
      log(LogLevel.fatal, m,
          fields: fields, error: error, stackTrace: stackTrace);
}
