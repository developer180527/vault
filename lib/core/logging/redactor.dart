import 'log_types.dart';

/// Scrubs sensitive data from logs before they reach any sink. Critical for a
/// privacy-first app: tokens, passwords, and auth headers must never land in a
/// log file (which may later be exported for a bug report). Applied centrally
/// so every sink receives already-redacted records.
class Redactor {
  const Redactor();

  static const _sensitiveKeySubstrings = {
    'password',
    'passwd',
    'secret',
    'token',
    'authorization',
    'auth',
    'cookie',
    'apikey',
    'api_key',
    'refresh',
    'access_token',
    'session',
    'credential',
  };

  // Bearer tokens and long base64/hex blobs that look like credentials.
  static final _messagePatterns = <RegExp>[
    RegExp(r'[Bb]earer\s+[A-Za-z0-9\-._~+/]+=*'),
    RegExp(r'\beyJ[A-Za-z0-9\-._~+/]{20,}=*'), // JWT
  ];

  static const _mask = '***';

  LogRecord record(LogRecord r) {
    final needsFieldScrub = r.fields.keys.any(_isSensitiveKey);
    final scrubbedMessage = _scrubMessage(r.message);
    if (!needsFieldScrub && scrubbedMessage == r.message) return r;
    return r.copyWith(
      message: scrubbedMessage,
      fields: needsFieldScrub ? _scrubFields(r.fields) : r.fields,
    );
  }

  bool _isSensitiveKey(String key) {
    final k = key.toLowerCase();
    return _sensitiveKeySubstrings.any(k.contains);
  }

  Map<String, Object?> _scrubFields(Map<String, Object?> fields) => {
        for (final e in fields.entries)
          e.key: _isSensitiveKey(e.key) ? _mask : e.value,
      };

  String _scrubMessage(String message) {
    var out = message;
    for (final p in _messagePatterns) {
      out = out.replaceAll(p, _mask);
    }
    return out;
  }
}
