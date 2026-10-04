import 'package:flutter/material.dart';

/// Design system for Commit. Every screen takes its colours, type, spacing
/// and corner radii from here.
class AppColors {
  const AppColors._();

  static const ink = Color(0xFF14201F);
  static const muted = Color(0xFF5C6867);
  static const faint = Color(0xFF8E9796);
  static const surface = Color(0xFFF6F5F1);
  static const card = Colors.white;
  static const line = Color(0xFFE4E2DA);

  /// Brand teal: primary actions, progress, selected states.
  static const brand = Color(0xFF1F5C56);
  static const brandSoft = Color(0xFFE3EFED);

  /// Warm tone: emergency access and things that need attention. Never red.
  static const warm = Color(0xFF8A5210);
  static const warmSoft = Color(0xFFFBF1DF);

  static const success = Color(0xFF1E7A4F);
  static const successSoft = Color(0xFFE2F3EA);

  static const disabledFill = Color(0xFFE9E7E0);
}

class AppSpace {
  const AppSpace._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AppRadius {
  const AppRadius._();
  static const double card = 20;
  static const double button = 16;
}

class AppText {
  const AppText._();

  static const _figures = [FontFeature.tabularFigures()];

  /// The countdown.
  static const timer = TextStyle(
    fontSize: 52,
    height: 1.05,
    fontWeight: FontWeight.w800,
    color: AppColors.ink,
    fontFeatures: _figures,
  );
  static const heading = TextStyle(
    fontSize: 28,
    height: 1.2,
    fontWeight: FontWeight.w800,
    color: AppColors.ink,
  );
  static const subheading = TextStyle(
    fontSize: 21,
    height: 1.25,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
  );
  static const title = TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w700,
    color: AppColors.ink,
  );
  static const body = TextStyle(
    fontSize: 16,
    height: 1.45,
    color: AppColors.ink,
  );
  static const bodyMuted = TextStyle(
    fontSize: 16,
    height: 1.45,
    color: AppColors.muted,
  );
  static const small = TextStyle(
    fontSize: 14,
    height: 1.4,
    color: AppColors.muted,
  );
  static const label = TextStyle(
    fontSize: 12.5,
    height: 1.2,
    letterSpacing: 0.9,
    fontWeight: FontWeight.w700,
    color: AppColors.muted,
  );
  static const button = TextStyle(fontSize: 17, fontWeight: FontWeight.w700);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.brand).copyWith(
    primary: AppColors.brand,
    surface: AppColors.surface,
    onSurface: AppColors.ink,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.surface,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: AppText.title,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1),
    cardTheme: CardThemeData(
      color: AppColors.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
    ),
  );
}
