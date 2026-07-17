import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../logging/vault_log.dart';

final _log = VaultLog.tag('localAuth');

/// THE device-local auth gate: one call, one bool.
///
/// Wraps the platform's own identity check — Face ID / Touch ID / Optic ID on
/// Apple platforms, biometrics or the lock-screen credential on Android,
/// Windows Hello on Windows. Vault never sees or stores anything biometric;
/// the OS runs the check and we take its yes/no. Any sensitive local surface
/// (media trash today; app lock, hidden albums, exports later) gates itself
/// with:
///
/// ```dart
/// if (await ref.read(localAuthGateProvider).authenticate(
///     reason: 'Unlock the trash')) { ... }
/// ```
///
/// **Fail-open on ability, fail-closed on refusal**: platforms with no auth
/// capability at all (Linux desktop, plain simulators) return true — otherwise
/// those users are permanently locked out of their own data, which protects
/// nothing. But once a prompt IS shown, only passing it returns true; cancel
/// or failure returns false.
class LocalAuthGate {
  LocalAuthGate({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// Whether this device can actually challenge the user (biometrics enrolled
  /// or a device credential set).
  Future<bool> get isAvailable async {
    try {
      // isDeviceSupported: a credential (passcode/PIN/pattern) exists.
      // canCheckBiometrics alone misses passcode-only devices.
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false; // plugin missing on this platform (e.g. Linux)
    }
  }

  /// Run the native prompt. [reason] is shown in the OS dialog — phrase it as
  /// what the user is unlocking, not why the app wants it.
  Future<bool> authenticate({required String reason}) async {
    try {
      if (!await isAvailable) {
        _log.info('local auth unavailable — allowing');
        return true;
      }
      final ok = await _auth.authenticate(
        localizedReason: reason,
        // biometricOnly false → the OS falls back to the device passcode /
        // PIN / password natively, so every enrolled device can pass.
        biometricOnly: false,
        persistAcrossBackgrounding: true, // survive backgrounding mid-prompt
      );
      _log.info('local auth', fields: {'ok': ok});
      return ok;
    } catch (e) {
      // A thrown error is not a refusal (no enrollment, lockout, transient
      // platform error) — but the prompt didn't pass either. Fail closed;
      // the caller's surface simply stays locked.
      _log.warn('local auth error', fields: {'error': '$e'});
      return false;
    }
  }
}

final localAuthGateProvider = Provider<LocalAuthGate>((ref) => LocalAuthGate());
