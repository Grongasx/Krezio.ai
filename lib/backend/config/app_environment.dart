import 'package:flutter/foundation.dart';

/// App execution environments
enum AppEnvironment {
  production,
  homologation,
}

/// Singleton configuration controller for environment flags and homologation features.
class EnvironmentConfig {
  static final ValueNotifier<AppEnvironment> environmentNotifier =
      ValueNotifier<AppEnvironment>(
        kDebugMode ? AppEnvironment.homologation : AppEnvironment.production,
      );

  static DateTime? _lastVersionTap;
  static int _versionTaps = 0;
  static bool get canToggle => kDebugMode || isHomologation;

  static AppEnvironment get current => environmentNotifier.value;

  static bool get isHomologation => environmentNotifier.value == AppEnvironment.homologation;
  static bool get isProduction => environmentNotifier.value == AppEnvironment.production;

  static void setEnvironment(AppEnvironment env) {
    environmentNotifier.value = env;
  }

  static void toggleEnvironment() {
    environmentNotifier.value = isHomologation
        ? AppEnvironment.production
        : AppEnvironment.homologation;
  }

  /// Seven consecutive taps unlock the inspector only for this app session.
  static bool tapVersion({DateTime? now}) {
    final currentTime = now ?? DateTime.now();
    final lastTap = _lastVersionTap;
    if (lastTap == null || currentTime.difference(lastTap) > const Duration(seconds: 1)) {
      _versionTaps = 0;
    }
    _lastVersionTap = currentTime;
    if (++_versionTaps < 7) return false;
    _versionTaps = 0;
    setEnvironment(AppEnvironment.homologation);
    return true;
  }
}
