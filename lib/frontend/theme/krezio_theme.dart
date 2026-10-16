import 'package:flutter/material.dart';

/// Design System Tokens and Theme Definitions for Krezio.ai (krezio-brand skill)
class KrezioColors {
  // Primary AI & Action Color
  static const Color aiPurple = Color(0xFF8B5CF6);
  static const Color aiPurpleLight = Color(0xFFA78BFA);
  static const Color aiPurpleDark = Color(0xFF7C3AED);

  // Growth / Success (Income)
  static const Color emeraldGreen = Color(0xFF10B981);
  static const Color emeraldGreenLight = Color(0xFF34D399);

  // Friendly Attention / Expense (NEVER blood red!)
  static const Color friendlyOrange = Color(0xFFF97316);
  static const Color friendlyOrangeLight = Color(0xFFFB923C);

  // Budget bands: green up to 79%, yellow 80–99%, red from 100% (a bright,
  // friendly red — still never blood red).
  static const Color budgetOk = emeraldGreen;
  static const Color budgetWarning = Color(0xFFF59E0B);
  static const Color budgetOver = Color(0xFFEF4444);

  // Light Mode Tokens
  static const Color lightBackground = Color(0xFFF9FAFB);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightPrimaryText = Color(0xFF111827);
  static const Color lightSecondaryText = Color(0xFF6B7280);
  static const Color lightBorder = Color(0xFFE5E7EB);

  // Dark Mode Tokens
  static const Color darkBackground = Color(0xFF121212);
  static const Color darkSurface = Color(0xFF1E1E1E);
  static const Color darkSurfaceVariant = Color(0xFF27272A);
  static const Color darkPrimaryText = Color(0xFFF3F4F6);
  static const Color darkSecondaryText = Color(0xFF9CA3AF);
  static const Color darkBorder = Color(0xFF3F3F46);
}

/// Type scale. Every `fontSize` in the screens comes from here — no loose
/// values. The steps keep the sizes the app already used most (11, 12, 13, 14)
/// so the scale adds consistency without changing how the app looks.
class KrezioFont {
  static const double micro = 10; // badges, legends of charts
  static const double caption = 11; // labels, nav bar, secondary metadata
  static const double small = 12; // secondary text, chips
  static const double bodySmall = 13; // list subtitles, dense body
  static const double body = 14; // default body text
  static const double bodyLarge = 16; // emphasized body, inputs
  static const double title = 18; // screen and card titles
  static const double headline = 24; // big numbers (balance, totals)
}

/// Spacing on a 4 pt grid (with a 2 pt half-step for hairline gaps). Every
/// padding/margin/gap in the screens comes from here.
class KrezioSpace {
  static const double hair = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

class KrezioTheme {
  static final BorderRadius borderRadius = BorderRadius.circular(16);

  static ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: KrezioColors.lightBackground,
    colorScheme: const ColorScheme.light(
      primary: KrezioColors.aiPurple,
      secondary: KrezioColors.emeraldGreen,
      tertiary: KrezioColors.friendlyOrange,
      surface: KrezioColors.lightSurface,
      onPrimary: Colors.white,
      onSurface: KrezioColors.lightPrimaryText,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: KrezioColors.lightSurface,
      elevation: 0,
      scrolledUnderElevation: 1,
      iconTheme: IconThemeData(color: KrezioColors.lightPrimaryText),
      titleTextStyle: TextStyle(
        color: KrezioColors.lightPrimaryText,
        fontSize: KrezioFont.title,
        fontWeight: FontWeight.bold,
      ),
    ),
    cardTheme: CardThemeData(
      color: KrezioColors.lightSurface,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: borderRadius),
    ),
  );

  static ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: KrezioColors.darkBackground,
    colorScheme: const ColorScheme.dark(
      primary: KrezioColors.aiPurple,
      secondary: KrezioColors.emeraldGreen,
      tertiary: KrezioColors.friendlyOrange,
      surface: KrezioColors.darkSurface,
      onPrimary: Colors.white,
      onSurface: KrezioColors.darkPrimaryText,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: KrezioColors.darkSurface,
      elevation: 0,
      scrolledUnderElevation: 1,
      iconTheme: IconThemeData(color: KrezioColors.darkPrimaryText),
      titleTextStyle: TextStyle(
        color: KrezioColors.darkPrimaryText,
        fontSize: KrezioFont.title,
        fontWeight: FontWeight.bold,
      ),
    ),
    cardTheme: CardThemeData(
      color: KrezioColors.darkSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: const BorderSide(color: KrezioColors.darkBorder, width: 1),
      ),
    ),
  );
}
