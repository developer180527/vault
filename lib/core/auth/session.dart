import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../logging/vault_log.dart';

final _log = VaultLog.tag('auth');

/// OAuth redirect for the app's PKCE flow. Must match the callback URL
/// registered in Pocket ID and the platform URL-scheme config.
const kOAuthRedirect = 'com.venug.vault://oauth';

/// A connected device session: which server, and this device's tokens.
@immutable
class Session {
  const Session({
    required this.serverHost,
    required this.deviceId,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpires,
    this.username = '',
  });

  /// Bare host, e.g. vault-server.taild29644.ts.net (always https).
  final String serverHost;
  final String deviceId;
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpires;
  final String username;

  Uri api(String path) => Uri.https(serverHost, path);

  Map<String, Object?> toJson() => {
        'server_host': serverHost,
        'device_id': deviceId,
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'access_expires': accessExpires.toIso8601String(),
        'username': username,
      };

  static Session fromJson(Map<String, Object?> j) => Session(
        serverHost: j['server_host'] as String,
        deviceId: j['device_id'] as String,
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        accessExpires: DateTime.parse(j['access_expires'] as String),
        username: (j['username'] as String?) ?? '',
      );

  Session copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? accessExpires,
    String? username,
  }) =>
      Session(
        serverHost: serverHost,
        deviceId: deviceId,
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        accessExpires: accessExpires ?? this.accessExpires,
        username: username ?? this.username,
      );
}

/// Thrown when the server knows the IdP identity but has no Vault account for
/// it — the UI offers first-admin setup (or "ask your admin").
class NoVaultAccount implements Exception {
  const NoVaultAccount(this.idToken);

  /// The verified ID token, reusable for an immediate /v1/setup attempt.
  final String idToken;
}

const _storageKey = 'vault_session_v1';

/// Holds the device session: null = not connected (mock mode). Persisted in
/// the platform keychain/keystore; loaded once at startup.
class SessionController extends AsyncNotifier<Session?> {
  final _storage = const FlutterSecureStorage();
  final _appAuth = const FlutterAppAuth();

  @override
  Future<Session?> build() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw == null) return null;
      return Session.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (e) {
      // Missing platform channel (tests) or corrupt entry → disconnected.
      _log.warn('session restore failed', fields: {'error': '$e'});
      return null;
    }
  }

  Future<void> _persist(Session? s) async {
    state = AsyncData(s);
    try {
      if (s == null) {
        await _storage.delete(key: _storageKey);
      } else {
        await _storage.write(key: _storageKey, value: jsonEncode(s.toJson()));
      }
    } catch (e, st) {
      _log.error('session persist failed', error: e, stackTrace: st);
    }
  }

  /// Runs the full login: discover the IdP from the server, PKCE via the
  /// system browser (passkey), then register this device. Throws
  /// [NoVaultAccount] when the admin hasn't created this user.
  Future<void> login(String serverHost) async {
    final host = _normalizeHost(serverHost);

    // 1. Ask the server how to log in (issuer + client id).
    final cfgRes = await http.get(Uri.https(host, '/v1/auth/config'));
    if (cfgRes.statusCode != 200) {
      throw Exception('server auth config: HTTP ${cfgRes.statusCode}');
    }
    final cfg = jsonDecode(cfgRes.body) as Map<String, Object?>;
    final issuer = cfg['issuer'] as String;
    final clientId = cfg['client_id'] as String;

    // 2. OIDC Authorization Code + PKCE against Pocket ID (system browser —
    // the passkey ceremony happens there, never inside the app).
    final result = await _appAuth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        clientId,
        kOAuthRedirect,
        discoveryUrl: '$issuer/.well-known/openid-configuration',
        scopes: const ['openid', 'profile', 'email'],
      ),
    );
    final idToken = result.idToken;
    if (idToken == null) {
      throw Exception('IdP returned no ID token');
    }

    // 3. Enroll this device with vaultd.
    await _register(host, idToken);
  }

  /// First-admin bootstrap: same as login, but presents the one-time setup
  /// code from the server logs alongside the ID token.
  Future<void> setupAdmin(String serverHost, String code, String idToken) async {
    final host = _normalizeHost(serverHost);
    final res = await http.post(
      Uri.https(host, '/v1/setup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'code': code,
        'id_token': idToken,
        'device_name': _deviceName(),
        'platform': defaultTargetPlatform.name,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('setup failed: ${_errOf(res)}');
    }
    await _installGrant(host, res.body);
    _log.info('admin bootstrap complete', fields: {'host': host});
  }

  Future<void> _register(String host, String idToken) async {
    final res = await http.post(
      Uri.https(host, '/v1/devices/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'id_token': idToken,
        'device_name': _deviceName(),
        'platform': defaultTargetPlatform.name,
      }),
    );
    if (res.statusCode == 403 && _errOf(res).contains('no vault account')) {
      throw NoVaultAccount(idToken);
    }
    if (res.statusCode != 200) {
      throw Exception('device registration failed: ${_errOf(res)}');
    }
    await _installGrant(host, res.body);
    _log.info('device registered', fields: {'host': host});
  }

  Future<void> _installGrant(String host, String body) async {
    final g = jsonDecode(body) as Map<String, Object?>;
    await _persist(Session(
      serverHost: host,
      deviceId: g['device_id'] as String,
      accessToken: g['access_token'] as String,
      refreshToken: g['refresh_token'] as String,
      accessExpires: DateTime.now()
          .add(Duration(seconds: (g['expires_in'] as num).toInt())),
    ));
  }

  /// In-flight refresh, shared by all concurrent callers (single-flight).
  Future<Session?>? _refreshing;

  /// Refreshes the token pair. Returns the new session, or null when the
  /// device has been revoked (session cleared → back to login).
  ///
  /// SINGLE-FLIGHT: refresh tokens are single-use and rotate on the server.
  /// At startup several providers (manifest, jobs feed, change feed, art
  /// headers…) each notice the expired access token and call this at once.
  /// Without coalescing they'd each POST the SAME token: the first rotates it,
  /// the rest present a now-stale token and — once past the server's rotation
  /// grace — get the device REVOKED, and their out-of-order persists could
  /// even store a stale token that bricks the NEXT launch. Sharing one
  /// in-flight future means exactly one rotation and one persist.
  Future<Session?> refresh() {
    final inflight = _refreshing;
    if (inflight != null) return inflight;
    final f = _doRefresh();
    _refreshing = f;
    // Clear only if we're still the current in-flight future (a later refresh
    // may have replaced us).
    f.whenComplete(() {
      if (identical(_refreshing, f)) _refreshing = null;
    });
    return f;
  }

  Future<Session?> _doRefresh() async {
    final s = state.asData?.value;
    if (s == null) return null;
    final res = await http.post(
      s.api('/v1/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': s.refreshToken}),
    );
    if (res.statusCode == 401) {
      _log.warn('refresh rejected — device revoked; disconnecting');
      await _persist(null);
      return null;
    }
    if (res.statusCode != 200) {
      // Transient (server down, offline): keep the session, caller retries.
      throw Exception('refresh failed: HTTP ${res.statusCode}');
    }
    final g = jsonDecode(res.body) as Map<String, Object?>;
    final next = s.copyWith(
      accessToken: g['access_token'] as String,
      refreshToken: g['refresh_token'] as String,
      accessExpires: DateTime.now()
          .add(Duration(seconds: (g['expires_in'] as num).toInt())),
    );
    await _persist(next);
    return next;
  }

  /// Stores server-reported identity (from the manifest) on the session.
  void noteUsername(String username) {
    final s = state.asData?.value;
    if (s != null && username.isNotEmpty && s.username != username) {
      _persist(s.copyWith(username: username));
    }
  }

  /// Disconnect this device (local: tokens dropped; the server row can be
  /// revoked from the admin CLI / future admin UI).
  Future<void> logout() => _persist(null);

  static String _normalizeHost(String input) {
    var v = input.trim();
    v = v.replaceFirst(RegExp(r'^https?://'), '');
    if (v.endsWith('/')) v = v.substring(0, v.length - 1);
    return v;
  }

  static String _deviceName() => switch (defaultTargetPlatform) {
        TargetPlatform.iOS => 'iPhone',
        TargetPlatform.android => 'Android phone',
        TargetPlatform.macOS => 'Mac',
        TargetPlatform.windows => 'Windows PC',
        TargetPlatform.linux => 'Linux PC',
        _ => 'Device',
      };

  static String _errOf(http.Response res) {
    try {
      final m = jsonDecode(res.body) as Map<String, Object?>;
      return (m['error'] as String?) ?? 'HTTP ${res.statusCode}';
    } catch (_) {
      return 'HTTP ${res.statusCode}';
    }
  }
}

final sessionProvider =
    AsyncNotifierProvider<SessionController, Session?>(SessionController.new);
