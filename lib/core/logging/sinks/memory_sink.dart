import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../log_types.dart';

/// Keeps the most recent [capacity] records in a ring buffer for the in-app log
/// viewer and for exporting a bug report. Being a [ChangeNotifier], the viewer
/// rebuilds live as logs arrive.
class MemoryLogSink extends ChangeNotifier implements LogSink {
  MemoryLogSink({this.capacity = 500});

  final int capacity;
  final ListQueue<LogRecord> _buffer = ListQueue<LogRecord>();

  List<LogRecord> get records => _buffer.toList(growable: false);

  @override
  void add(LogRecord record) {
    _buffer.addLast(record);
    while (_buffer.length > capacity) {
      _buffer.removeFirst();
    }
    notifyListeners();
  }

  void clear() {
    _buffer.clear();
    notifyListeners();
  }

  /// The whole buffer as text, for copy/share in a bug report.
  String export() => _buffer.map((r) => formatLogLine(r)).join('\n');

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
