import 'package:flutter/foundation.dart';

import '../log_types.dart';

/// Writes to the developer console via [debugPrint] (rate-limited, no
/// truncation). Intended for debug/profile builds; release builds rely on the
/// file + memory sinks instead.
class ConsoleLogSink extends LogSink {
  ConsoleLogSink();

  @override
  void add(LogRecord record) {
    debugPrint(formatLogLine(record, withGlyph: true));
  }
}
