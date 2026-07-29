import 'package:flutter/material.dart';

import 'colors.dart';

/// Single place where the app's look is defined.
///
/// Before this, screens styled their own AppBars, cards and inputs — five of
/// them repainted the AppBar by hand while the rest relied on framework
/// defaults, so the same surface looked different depending on where you were.
/// Those defaults also differ between Material 2 and 3 (an AppBar takes its
/// colour from `primary` under M2 and from `surface` under M3), which made the
/// appearance depend on the Flutter version rather than on our intent.
class AppTheme {
  const AppTheme._();

  static const _colorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.mainColor,
    onPrimary: AppColors.niceWhite,
    secondary: AppColors.mainColor,
    onSecondary: AppColors.niceWhite,
    error: AppColors.niceRed,
    onError: AppColors.niceWhite,
    background: AppColors.niceWhite,
    onBackground: Colors.black,
    surface: AppColors.niceWhite,
    onSurface: Colors.black,
  );

  static ThemeData get light => ThemeData(
        colorScheme: _colorScheme,

        // Green bar, white content, flat — stated outright so it no longer
        // depends on which Material version is in force.
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.mainColor,
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          // Without this the bar tints as content scrolls under it, which
          // reads as a rendering glitch rather than a deliberate effect.
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Colors.white),
        ),

        cardTheme: CardTheme(
          elevation: 2,
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.mainColor, width: 1.5),
          ),
        ),

        chipTheme: ChipThemeData(
          backgroundColor: Colors.grey.shade100,
          selectedColor: AppColors.mainColor.withOpacity(0.18),
          labelStyle: const TextStyle(fontSize: 12),
          side: BorderSide.none,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),

        // Floating everywhere: several screens already asked for it per call.
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),

        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: AppColors.mainColor,
        ),

        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: AppColors.mainColor,
          foregroundColor: Colors.white,
        ),

        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: Colors.white,
          selectedItemColor: AppColors.mainColor,
          unselectedItemColor: Colors.grey.shade600,
          type: BottomNavigationBarType.fixed,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
          elevation: 0,
        ),

        listTileTheme: ListTileThemeData(
          selectedColor: AppColors.mainColor,
          selectedTileColor: AppColors.mainColor.withOpacity(0.08),
        ),

        // Colour only — leaving `space` alone so dividers used as block
        // separators keep their spacing.
        dividerTheme: DividerThemeData(
          thickness: 1,
          color: Colors.grey.shade200,
        ),

        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: AppColors.mainColor),
        ),

        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.mainColor,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );
}
