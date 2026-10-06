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
        fontSize: 18,
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
        fontSize: 18,
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
