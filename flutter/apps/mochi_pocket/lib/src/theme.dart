// Mochi's design system on Android: the iPhone's tokens (iOS/MochiPocket/Theme.swift) adapted to Material, in light
// and dark.
//
// The look is soft "claymorphism": chunky rounded cards on a warm backdrop with a hairline rim and a gentle double
// shadow. The rules behind it, as on the iPhone:
// - Text is at least 4.5:1 against what it sits on (cards, wells and the backdrop), in both themes
//   (test/theme_test.dart measures every pair). Mochi's peach is only for fills and glows; text, icons and filled
//   buttons use terracotta ([MochiPalette.tint]); secondary text is a warm grey.
// - Text is Nunito (bundled, SIL OFL), the open rounded face closest to the iPhone's SF Pro Rounded, at the iPhone's
//   weights, and follows the system font size.
// - Every control has a 48 dp touch target (Android's minimum; the iPhone uses 44 pt), gives feedback when pressed,
//   and has a spoken label.

import 'package:flutter/material.dart';

/// The bundled rounded face (pubspec.yaml `fonts:`).
const String mochiFont = 'Nunito';

/// Colour tokens. Contrast is measured on [surface] unless noted.
@immutable
class MochiPalette extends ThemeExtension<MochiPalette> {
  const MochiPalette({
    required this.brightness,
    required this.ink,
    required this.inkSecondary,
    required this.peach,
    required this.tint,
    required this.onTint,
    required this.success,
    required this.warning,
    required this.danger,
    required this.vip,
    required this.indigo,
    required this.pet,
    required this.play,
    required this.backgroundTop,
    required this.backgroundBottom,
    required this.surface,
    required this.sunken,
    required this.stroke,
    required this.shadow,
    required this.bubbleHighlight,
  });

  /// The iPhone's palette. Three tokens are a shade darker or lighter than iOS so that text also reaches 4.5:1 on
  /// wells and at the bottom of the backdrop, where Android shows it: [success], [warning] and [backgroundBottom].
  static const MochiPalette light = MochiPalette(
    brightness: Brightness.light,
    ink: Color(0xFF2B2118), // 15.4:1
    inkSecondary: Color(0xFF6E6259), // 5.8:1 (the system grey is about 3.4:1 here)
    peach: Color(0xFFF28C61), // fills and glows only: 2.4:1
    tint: Color(0xFFB4471C), // 5.3:1; white on it 5.4:1
    onTint: Color(0xFFFFFFFF),
    success: Color(0xFF1D7346),
    warning: Color(0xFFA84D08),
    danger: Color(0xFFB42318),
    vip: Color(0xFFB7791F), // an icon: 3:1 is enough (3.6:1)
    indigo: Color(0xFF4F46E5),
    pet: Color(0xFFC2335A),
    play: Color(0xFF2F7D4F),
    backgroundTop: Color(0xFFFFF6EE),
    backgroundBottom: Color(0xFFFCE8DA),
    surface: Color(0xFFFFFCF8),
    sunken: Color(0xFFF6ECE3),
    stroke: Color(0xFFEFDCCB),
    shadow: Color(0xFF7A4A2A),
    bubbleHighlight: Color(0xFFFCE9DD),
  );

  /// Warm dark clay: the same hues, lifted so every text token stays above 5.5:1 on cards and wells. Filled buttons
  /// turn light terracotta with dark text (7.2:1).
  static const MochiPalette dark = MochiPalette(
    brightness: Brightness.dark,
    ink: Color(0xFFF8EEE6), // 13.9:1
    inkSecondary: Color(0xFFC4B2A5), // 7.8:1
    peach: Color(0xFFF28C61),
    tint: Color(0xFFF2895B), // 6.4:1
    onTint: Color(0xFF2A1006),
    success: Color(0xFF6BD39C),
    warning: Color(0xFFF5A85E),
    danger: Color(0xFFFF8F85),
    vip: Color(0xFFE9B95C),
    indigo: Color(0xFFA9A4FF),
    pet: Color(0xFFFF8DAA),
    play: Color(0xFF79D6A0),
    backgroundTop: Color(0xFF1C1511),
    backgroundBottom: Color(0xFF261B15),
    surface: Color(0xFF2A201A),
    sunken: Color(0xFF382B23),
    stroke: Color(0xFF45362C),
    shadow: Color(0xFF000000),
    bubbleHighlight: Color(0xFF4A2C1E),
  );

  final Brightness brightness;

  /// Primary text.
  final Color ink;

  /// Secondary text.
  final Color inkSecondary;

  /// Mochi's peach, for fills, glows and art; never text.
  final Color peach;

  /// Terracotta for text, icons and filled buttons.
  final Color tint;

  /// Text and icons on [tint].
  final Color onTint;
  final Color success;
  final Color warning;
  final Color danger;

  /// The VIP star.
  final Color vip;
  final Color indigo;
  final Color pet;
  final Color play;
  final Color backgroundTop;
  final Color backgroundBottom;

  /// Cards.
  final Color surface;

  /// Wells inside cards: fields, chips, round buttons.
  final Color sunken;
  final Color stroke;

  final Color shadow;

  /// The speech bubble while it's the newest thing Mochi said.
  final Color bubbleHighlight;

  bool get isDark => brightness == Brightness.dark;

  @override
  MochiPalette copyWith({Color? tint, Color? surface}) => MochiPalette(
    brightness: brightness,
    ink: ink,
    inkSecondary: inkSecondary,
    peach: peach,
    tint: tint ?? this.tint,
    onTint: onTint,
    success: success,
    warning: warning,
    danger: danger,
    vip: vip,
    indigo: indigo,
    pet: pet,
    play: play,
    backgroundTop: backgroundTop,
    backgroundBottom: backgroundBottom,
    surface: surface ?? this.surface,
    sunken: sunken,
    stroke: stroke,
    shadow: shadow,
    bubbleHighlight: bubbleHighlight,
  );

  @override
  MochiPalette lerp(MochiPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return MochiPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      ink: mix(ink, other.ink),
      inkSecondary: mix(inkSecondary, other.inkSecondary),
      peach: mix(peach, other.peach),
      tint: mix(tint, other.tint),
      onTint: mix(onTint, other.onTint),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      vip: mix(vip, other.vip),
      indigo: mix(indigo, other.indigo),
      pet: mix(pet, other.pet),
      play: mix(play, other.play),
      backgroundTop: mix(backgroundTop, other.backgroundTop),
      backgroundBottom: mix(backgroundBottom, other.backgroundBottom),
      surface: mix(surface, other.surface),
      sunken: mix(sunken, other.sunken),
      stroke: mix(stroke, other.stroke),
      shadow: mix(shadow, other.shadow),
      bubbleHighlight: mix(bubbleHighlight, other.bubbleHighlight),
    );
  }
}

/// An 8-point rhythm.
abstract final class Space {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
}

abstract final class Radii {
  static const double card = 26;
  static const double inner = 16;
  static const double tile = 10;
}

/// Android's minimum touch target.
const double touchTarget = 48;

/// The iPhone's Dynamic Type styles (SF Pro Rounded, `Font.mochi`) as Nunito, in sp so they follow the font size
/// setting. Weights mirror the iPhone: the big title heavy, section titles bold, headlines semibold, everything else
/// regular (with medium or semibold for emphasis, as the iPhone's `.mochi(.footnote, .semibold)`).
class MochiType {
  const MochiType(this.palette);

  final MochiPalette palette;

  static const TextStyle _base = TextStyle(fontFamily: mochiFont, fontFamilyFallback: ['sans-serif']);

  TextStyle get largeTitle => _base.copyWith(fontSize: 32, fontWeight: FontWeight.w800, height: 1.15, color: palette.ink);
  TextStyle get title3 => _base.copyWith(fontSize: 20, fontWeight: FontWeight.w700, height: 1.25, color: palette.ink);
  TextStyle get headline => _base.copyWith(fontSize: 17, fontWeight: FontWeight.w600, height: 1.3, color: palette.ink);
  TextStyle get body => _base.copyWith(fontSize: 16, fontWeight: FontWeight.w400, height: 1.35, color: palette.ink);
  TextStyle get subheadline => _base.copyWith(fontSize: 15, fontWeight: FontWeight.w400, height: 1.35, color: palette.ink);
  TextStyle get footnote => _base.copyWith(fontSize: 13, fontWeight: FontWeight.w400, height: 1.35, color: palette.inkSecondary);
  TextStyle get caption => _base.copyWith(fontSize: 12, fontWeight: FontWeight.w400, height: 1.3, color: palette.inkSecondary);

  /// Button labels.
  TextStyle get label => _base.copyWith(fontSize: 15, fontWeight: FontWeight.w600, height: 1.2);
}

extension MochiThemeOf on BuildContext {
  MochiPalette get palette => Theme.of(this).extension<MochiPalette>() ?? MochiPalette.light;

  MochiType get type => MochiType(palette);
}

ThemeData mochiTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? MochiPalette.dark : MochiPalette.light;
  final type = MochiType(p);
  final scheme = ColorScheme.fromSeed(
    seedColor: MochiPalette.light.tint,
    brightness: brightness,
    primary: p.tint,
    onPrimary: p.onTint,
    surface: p.surface,
    onSurface: p.ink,
    onSurfaceVariant: p.inkSecondary,
    surfaceContainerHighest: p.sunken,
    error: p.danger,
    outline: p.stroke,
    outlineVariant: p.stroke,
  );
  final shape = WidgetStateProperty.all<OutlinedBorder>(const StadiumBorder());
  const minimum = Size(touchTarget, touchTarget);
  final label = WidgetStateProperty.all(type.label);
  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: mochiFont,
    extensions: [p],
    scaffoldBackgroundColor: p.backgroundTop,
    canvasColor: p.surface,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    // Predictive back on Android 14+: the page shrinks back as you swipe, and settles if you change your mind.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.android: PredictiveBackPageTransitionsBuilder()}),
    textTheme: TextTheme(
      headlineMedium: type.largeTitle,
      titleLarge: type.title3,
      titleMedium: type.headline,
      bodyLarge: type.body,
      bodyMedium: type.subheadline,
      bodySmall: type.footnote,
      labelLarge: type.label,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: shape,
        minimumSize: WidgetStateProperty.all(minimum),
        padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 20)),
        textStyle: label,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: shape,
        minimumSize: WidgetStateProperty.all(minimum),
        padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 20)),
        foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? p.inkSecondary : p.tint),
        side: WidgetStateProperty.all(BorderSide(color: p.stroke, width: 1.5)),
        textStyle: label,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(minimumSize: WidgetStateProperty.all(minimum), foregroundColor: WidgetStateProperty.all(p.tint), textStyle: label),
    ),
    iconButtonTheme: IconButtonThemeData(style: ButtonStyle(minimumSize: WidgetStateProperty.all(minimum))),
    dividerTheme: DividerThemeData(color: p.stroke, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.ink,
      contentTextStyle: type.subheadline.copyWith(color: p.surface),
      actionTextColor: p.isDark ? MochiPalette.light.tint : MochiPalette.dark.tint,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      showDragHandle: true,
      dragHandleColor: p.inkSecondary,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card))),
    ),
    listTileTheme: ListTileThemeData(iconColor: p.tint, textColor: p.ink, titleTextStyle: type.body, minVerticalPadding: 12),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      titleTextStyle: type.title3,
      contentTextStyle: type.subheadline,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.card)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.backgroundTop,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: type.headline,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.sunken,
      border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.inner)), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: 14),
      hintStyle: type.body.copyWith(color: p.inkSecondary),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.tint),
    tooltipTheme: TooltipThemeData(textStyle: type.footnote.copyWith(color: p.surface)),
  );
}
