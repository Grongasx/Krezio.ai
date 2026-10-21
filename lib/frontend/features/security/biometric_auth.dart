import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Fingerprint or face unlock through the system (`local_auth`). On devices
/// without it (and on the web) only the PIN is offered.
class BiometricAuth {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> available() async {
    if (kIsWeb) return false;
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (e) {
      debugPrint('[BiometricAuth] $e');
      return false;
    }
  }

  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(localizedReason: 'Desbloqueie o Krezio.ai', biometricOnly: true);
    } catch (e) {
      debugPrint('[BiometricAuth] $e');
      return false;
    }
  }
}
