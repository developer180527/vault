import 'dart:io';

import '../log_types.dart';

/// Appends records to a size-rotated log file, so release builds keep a
/// persistent diagnostic trail without unbounded disk growth. Writes are
/// buffered by the [IOSink] and flushed periodically (and immediately on
/// error/fatal, which are the records you most need after a crash). Never
/// throws out of [add] — a disk problem must not take down the app.
class FileLogSink extends LogSink {
  FileLogSink(
    this.directory, {
    this.baseName = 'vault.log',
    this.maxBytes = 5 * 1024 * 1024,
    this.maxFiles = 3,
  });

  final String directory;
  final String baseName;
  final int maxBytes;
  final int maxFiles;

  IOSink? _sink;
  int _size = 0;
  bool _broken = false;

  File get _file => File('$directory/$baseName');

  /// Opens the current log file for appending. Call once at startup.
  Future<void> open() async {
    try {
      Directory(directory).createSync(recursive: true);
      _size = _file.existsSync() ? _file.lengthSync() : 0;
      _sink = _file.openWrite(mode: FileMode.append);
    } catch (_) {
      _broken = true; // degrade silently; other sinks still work
    }
  }

  @override
  void add(LogRecord record) {
    if (_broken || _sink == null) return;
    try {
      final line = '${formatLogLine(record)}\n';
      _sink!.write(line);
      _size += line.length;
      if (record.level.index >= LogLevel.error.index) {
        _sink!.flush();
      }
      if (_size >= maxBytes) _rotate();
    } catch (_) {
      _broken = true;
    }
  }

  void _rotate() {
    try {
      _sink?.flush();
      _sink?.close();
      // Shift vault.log → vault.1.log → vault.2.log … dropping the oldest.
      for (var i = maxFiles - 1; i >= 1; i--) {
        final src = File('$directory/$baseName.$i');
        if (src.existsSync()) {
          if (i == maxFiles - 1) {
            src.deleteSync();
          } else {
            src.renameSync('$directory/$baseName.${i + 1}');
          }
        }
      }
      if (_file.existsSync()) _file.renameSync('$directory/$baseName.1');
      _sink = _file.openWrite(mode: FileMode.append);
      _size = 0;
    } catch (_) {
      _broken = true;
    }
  }

  @override
  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
  }
}
