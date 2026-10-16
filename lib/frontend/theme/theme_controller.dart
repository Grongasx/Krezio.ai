import 'package:flutter/material.dart';

/// Light, dark or follow the system — the user's choice, saved and restored.
class ThemeController {
  ThemeController._();

  /// Preference key ("system", "light" or "dark").
  static const String pref = 'theme_mode';

  static final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(ThemeMode.dark);

  static ThemeMode parse(String? value) => switch (value) {
        'system' => ThemeMode.system,
        'light' => ThemeMode.light,
        _ => ThemeMode.dark,
      };

  static String nameOf(ThemeMode m) => switch (m) {
        ThemeMode.system => 'system',
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
      };

  static String labelOf(ThemeMode m) => switch (m) {
        ThemeMode.system => 'Seguir o sistema',
        ThemeMode.light => 'Claro',
        ThemeMode.dark => 'Escuro',
      };

  /// Whether the app is dark right now under [m].
  static bool isDark(ThemeMode m, Brightness platform) =>
      m == ThemeMode.dark || (m == ThemeMode.system && platform == Brightness.dark);
}
