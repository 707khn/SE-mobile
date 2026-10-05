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
///
/// Светлая и тёмная собираются одной функцией с разными цветами: иначе через
/// пару правок они разъедутся и что-нибудь окажется белым текстом на белом.
class AppTheme {
  const AppTheme._();

  /// The seven sizes the app uses, down from thirteen ad-hoc values that made
  /// equivalent labels look different from one screen to the next.
  ///
  /// caption 11 · secondary 12 · body 13 · emphasis 15 · title 18 ·
  /// headline 22 · display 28
  static const textScale = TextTheme(
    labelSmall: TextStyle(fontSize: 11),
    bodySmall: TextStyle(fontSize: 12),
    bodyMedium: TextStyle(fontSize: 13),
    bodyLarge: TextStyle(fontSize: 15),
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
    headlineSmall: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
    displaySmall: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
  );

  static ThemeData get light => _build(
        brightness: Brightness.light,
        // Зелёный фирменный цвет на светлом читается как есть.
        accent: AppColors.mainColor,
        page: AppColors.pageLight,
        card: AppColors.cardLight,
        onSurface: AppColors.inkLight,
        muted: AppColors.mutedLight,
        hairline: AppColors.hairlineLight,
      );

  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        // На тёмном фоне #018041 почти чёрный — берём осветлённый той же
        // гаммы, иначе кнопки и выделения пропадают.
        accent: AppColors.mainColorDark,
        page: AppColors.pageDark,
        card: AppColors.cardDark,
        onSurface: AppColors.inkDark,
        muted: AppColors.mutedDark,
        hairline: AppColors.hairlineDark,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color accent,
    required Color page,
    required Color card,
    required Color onSurface,
    required Color muted,
    required Color hairline,
  }) {
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: page,
      cardColor: card,
      // hintColor служит приглушённым цветом для подписей: экраны берут его
      // через context.muted, чтобы не писать grey.shade600 руками.
      hintColor: muted,
      dividerColor: hairline,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: accent,
        onPrimary: Colors.white,
        secondary: accent,
        onSecondary: Colors.white,
        error: brightness == Brightness.dark
            ? AppColors.niceRedDark
            : AppColors.niceRed,
        onError: Colors.white,
        background: page,
        onBackground: onSurface,
        surface: card,
        onSurface: onSurface,
      ),
      textTheme: textScale.apply(bodyColor: onSurface, displayColor: onSurface),

      // Зелёная шапка с белым текстом в обеих темах: это узнаваемый вид
      // приложения, и менять его в темноте не за чем. Сказано явно, чтобы не
      // зависеть от версии Material.
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.mainColor,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        // Без этого бар подкрашивается при прокрутке контента под ним, и это
        // выглядит как artefact отрисовки, а не как задумка.
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: Colors.white),
      ),

      cardTheme: CardThemeData(
        elevation: brightness == Brightness.dark ? 0 : 2,
        color: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        isDense: true,
        hintStyle: TextStyle(color: muted),
        labelStyle: TextStyle(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),

      // Chips need a visible outline: a pale fill with no border and an
      // unspecified label colour left them almost invisible on white.
      chipTheme: ChipThemeData(
        backgroundColor: card,
        selectedColor: accent.withOpacity(brightness == Brightness.dark ? 0.24 : 0.15),
        labelStyle: TextStyle(
          fontSize: 12,
          color: onSurface,
          fontWeight: FontWeight.w500,
        ),
        secondaryLabelStyle: TextStyle(
          fontSize: 12,
          color: accent,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide(color: hairline),
        checkmarkColor: accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      // Floating everywhere: several screens already asked for it per call.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),

      drawerTheme: DrawerThemeData(backgroundColor: card),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: Colors.white,
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: card,
        selectedItemColor: accent,
        unselectedItemColor: muted,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
        elevation: 0,
      ),

      listTileTheme: ListTileThemeData(
        selectedColor: accent,
        selectedTileColor: accent.withOpacity(0.08),
        iconColor: muted,
      ),

      iconTheme: IconThemeData(color: muted),

      // Colour only — leaving `space` alone so dividers used as block
      // separators keep their spacing.
      dividerTheme: DividerThemeData(thickness: 1, color: hairline),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }
}

/// Цвета, которые экраны раньше писали руками — `Colors.white` для карточки,
/// `Colors.grey.shade600` для подписи. В тёмной теме такие значения дают
/// белое на белом и серое на чёрном, поэтому берём их из темы.
extension AppThemeColors on BuildContext {
  ThemeData get _t => Theme.of(this);

  bool get isDark => _t.brightness == Brightness.dark;

  /// Фон страницы под карточками.
  Color get pageColor => _t.scaffoldBackgroundColor;

  /// Поверхность карточки, плитки, поля ввода.
  Color get cardSurface => _t.cardColor;

  /// Основной цвет текста.
  Color get inkColor => _t.colorScheme.onSurface;

  /// Приглушённый текст и иконки: подписи, единицы, «записей нет».
  Color get mutedColor => _t.hintColor;

  /// Тонкая линия: рамки, разделители.
  Color get hairlineColor => _t.dividerColor;

  /// Фирменный зелёный, осветлённый в тёмной теме.
  Color get accentColor => _t.colorScheme.primary;

  /// Тень под карточкой. В темноте тени не видно, поэтому там её и нет —
  /// вместо неё карточку отделяет собственный цвет поверхности.
  List<BoxShadow> get cardShadow => isDark
      ? const []
      : [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ];
}
