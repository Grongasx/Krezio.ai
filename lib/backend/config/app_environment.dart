import 'package:flutter/foundation.dart';

/// App execution environments
enum AppEnvironment {
  production,
  homologation,
}

/// Singleton configuration controller for environment flags and homologation features.
class EnvironmentConfig {
  static final ValueNotifier<AppEnvironment> environmentNotifier =
      ValueNotifier<AppEnvironment>(AppEnvironment.homologation);

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
}
