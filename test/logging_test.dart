import 'package:flutter_test/flutter_test.dart';

import 'package:vault/core/logging/log_types.dart';
import 'package:vault/core/logging/redactor.dart';
import 'package:vault/core/logging/sinks/memory_sink.dart';
import 'package:vault/core/logging/vault_log.dart';

class _CaptureSink extends LogSink {
  final records = <LogRecord>[];
  @override
  void add(LogRecord record) => records.add(record);
}

void main() {
  const redactor = Redactor();

  group('Redactor', () {
    test('masks sensitive field keys', () {
      final r = redactor.record(LogRecord(
        level: LogLevel.info,
        tag: 'auth',
        message: 'login',
        fields: {'user': 'vg', 'access_token': 'abc123', 'password': 'hunter2'},
      ));
      expect(r.fields['user'], 'vg');
      expect(r.fields['access_token'], '***');
      expect(r.fields['password'], '***');
    });

    test('masks bearer tokens and JWTs in messages', () {
      final r = redactor.record(LogRecord(
        level: LogLevel.info,
        tag: 'net',
        message: 'sent Bearer abcDEF123.-_ to server',
      ));
      expect(r.message, contains('***'));
      expect(r.message, isNot(contains('abcDEF123')));
    });

    test('leaves clean records untouched (same instance)', () {
      final r = LogRecord(level: LogLevel.info, tag: 't', message: 'hello');
      expect(identical(redactor.record(r), r), isTrue);
    });
  });

  group('MemoryLogSink', () {
    test('keeps only the last [capacity] records', () {
      final sink = MemoryLogSink(capacity: 3);
      for (var i = 0; i < 5; i++) {
        sink.add(LogRecord(level: LogLevel.info, tag: 't', message: 'm$i'));
      }
      expect(sink.records.map((r) => r.message), ['m2', 'm3', 'm4']);
    });
  });

  group('VaultLog dispatch', () {
    setUp(VaultLog.reset);
    tearDown(VaultLog.reset);

    test('drops records below minLevel and redacts the rest', () async {
      final capture = _CaptureSink();
      await VaultLog.init(sinks: [capture]);
      VaultLog.minLevel = LogLevel.warn;

      final log = VaultLog.tag('t');
      log.debug('noisy');
      log.warn('problem', fields: {'token': 'secret'});
      log.error('boom');

      expect(capture.records.map((r) => r.message), ['problem', 'boom']);
      expect(capture.records.first.fields['token'], '***');
    });
  });
}
