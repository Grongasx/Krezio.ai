import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Where the PIN's hash and the lock settings are kept (the device's local
/// storage in the app; a map in tests). Never synced to the cloud.
abstract class PinStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class MemoryPinStore implements PinStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String? value) async => value == null ? data.remove(key) : data[key] = value;
}

/// Result of a PIN try.
enum PinCheck { ok, wrong, lockedOut }

/// App lock by PIN (4 to 6 digits). The PIN is kept only as a salted,
/// stretched SHA-256 hash, never in text. After 5 wrong tries the next try
/// waits 30 seconds. Pure Dart: [now] can be injected.
class PinLock {
  static const _kHash = 'pin_hash';
  static const _kSalt = 'pin_salt';
  static const _kBiometrics = 'lock_biometrics';
  static const _kAutoLockSeconds = 'lock_after_seconds';
  static const maxTries = 5;
  static const lockout = Duration(seconds: 30);
  static const _rounds = 10000;

  final PinStore store;
  final DateTime Function() _clock;

  int _wrongTries = 0;
  DateTime? _lockedUntil;

  PinLock(this.store, {DateTime Function()? now}) : _clock = now ?? DateTime.now;

  /// 4 to 6 digits.
  static bool isValidPin(String pin) => RegExp(r'^\d{4,6}$').hasMatch(pin);

  static String hash(String pin, String salt) {
    List<int> digest = utf8.encode('$salt:$pin');
    for (var i = 0; i < _rounds; i++) {
      digest = sha256.convert([...digest, ...utf8.encode(salt)]).bytes;
    }
    return base64Encode(digest);
  }

  Future<bool> get isEnabled async => (await store.read(_kHash)) != null;

  /// Sets (or changes) the PIN. [confirmation] must match. False when the PIN
  /// is invalid or doesn't match.
  Future<bool> setPin(String pin, String confirmation) async {
    if (!isValidPin(pin) || pin != confirmation) return false;
    final rnd = Random.secure();
    final salt = base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    await store.write(_kSalt, salt);
    await store.write(_kHash, hash(pin, salt));
    _wrongTries = 0;
    _lockedUntil = null;
    return true;
  }

  Future<void> disable() async {
    await store.write(_kHash, null);
    await store.write(_kSalt, null);
    await store.write(_kBiometrics, null);
  }

  /// Seconds still to wait before another try (0 = can try now).
  int get secondsLeft {
    final until = _lockedUntil;
    if (until == null) return 0;
    final left = until.difference(_clock()).inMilliseconds;
    return left <= 0 ? 0 : (left / 1000).ceil();
  }

  /// Whether [pin] is right, without counting a wrong try (used while the
  /// user is still typing: a 6-digit PIN is checked at 4 and 5 digits too).
  Future<bool> matches(String pin) async {
    if (secondsLeft > 0) return false;
    final stored = await store.read(_kHash);
    final salt = await store.read(_kSalt);
    if (stored == null || salt == null) return true;
    final ok = hash(pin, salt) == stored;
    if (ok) {
      _wrongTries = 0;
      _lockedUntil = null;
    }
    return ok;
  }

  Future<PinCheck> check(String pin) async {
    if (secondsLeft > 0) return PinCheck.lockedOut;
    final stored = await store.read(_kHash);
    final salt = await store.read(_kSalt);
    if (stored == null || salt == null) return PinCheck.ok;
    if (hash(pin, salt) == stored) {
      _wrongTries = 0;
      _lockedUntil = null;
      return PinCheck.ok;
    }
    _wrongTries++;
    if (_wrongTries >= maxTries) {
      _wrongTries = 0;
      _lockedUntil = _clock().add(lockout);
      return PinCheck.lockedOut;
    }
    return PinCheck.wrong;
  }

  int get triesLeft => maxTries - _wrongTries;

  Future<bool> get biometricsEnabled async => (await store.read(_kBiometrics)) == 'true';
  Future<void> setBiometrics(bool on) => store.write(_kBiometrics, on ? 'true' : null);

  /// Lock after this long in the background (default 1 minute).
  Future<Duration> get autoLockAfter async => Duration(seconds: int.tryParse(await store.read(_kAutoLockSeconds) ?? '') ?? 60);
  Future<void> setAutoLockAfter(Duration d) => store.write(_kAutoLockSeconds, '${d.inSeconds}');

  /// Whether the app should ask for the PIN when it comes back after having
  /// been in the background since [backgroundSince].
  Future<bool> shouldLockOnResume(DateTime? backgroundSince) async {
    if (backgroundSince == null || !await isEnabled) return false;
    return _clock().difference(backgroundSince) >= await autoLockAfter;
  }
}
