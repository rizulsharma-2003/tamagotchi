// Mochi's design system: the iPhone's tokens (iOS/MochiPocket/Theme.swift) adapted to Material, in light and dark,
// as mochi_pocket's theme.dart has them, with a desktop variant (pointer-sized controls, keyboard focus rings).
//
// The look is soft "claymorphism": chunky rounded cards on a warm backdrop with a hairline rim and a gentle double
// shadow. The rules behind it:
// - Text is at least 4.5:1 against what it sits on (cards, wells and the backdrop), in both themes. Mochi's peach is
//   only for fills and glows; text, icons and filled buttons use terracotta ([MochiPalette.tint]).
// - Text is Nunito (bundled with this package, SIL OFL), the open rounded face closest to SF Pro Rounded, and follows
//   the system text size.
// - Every control has a spoken label and gives feedback when pressed; on the desktop every control is reachable with
//   Tab and shows a clear focus ring.

import 'package:flutter/material.dart';

/// The bundled rounded face, as Flutter names a package's font.
const String mochiFontFamily = 'packages/mochi_ui/Nunito';

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
    required this.focus,
  });

  static const MochiPalette light = MochiPalette(
    brightness: Brightness.light,
    ink: Color(0xFF2B2118), // 15.4:1
    inkSecondary: Color(0xFF6E6259), // 5.8:1
    peach: Color(0xFFF28C61), // fills and glows only
    tint: Color(0xFFB4471C), // 5.3:1; white on it 5.4:1
    onTint: Color(0xFFFFFFFF),
    success: Color(0xFF1D7346),
    warning: Color(0xFFA84D08),
    danger: Color(0xFFB42318),
    vip: Color(0xFFB7791F),
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
    focus: Color(0xFF1F5FBF), // the keyboard focus ring: 3:1+ against every surface
  );

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
    focus: Color(0xFF8DB8FF),
  );

  final Brightness brightness;
  final Color ink;
  final Color inkSecondary;

  /// Mochi's peach, for fills, glows and art; never text.
  final Color peach;

  /// Terracotta for text, icons and filled buttons.
  final Color tint;
  final Color onTint;
  final Color success;
  final Color warning;
  final Color danger;
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
  final Color bubbleHighlight;

  /// The keyboard focus ring.
  final Color focus;

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
    focus: focus,
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
      focus: mix(focus, other.focus),
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
  static const double card = 22;
  static const double inner = 14;
  static const double tile = 10;
}

/// Phones (48 dp targets) or desktops (pointer-sized controls, focus rings, visible scrollbars).
enum MochiFormFactor { touch, desktop }

/// The type scale in Nunito, in logical pixels so it follows the system text size.
class MochiType {
  const MochiType(this.palette, {this.formFactor = MochiFormFactor.touch});

  final MochiPalette palette;
  final MochiFormFactor formFactor;

  static const TextStyle _base = TextStyle(fontFamily: mochiFontFamily, fontFamilyFallback: ['Segoe UI', 'sans-serif']);

  /// Desktop text runs a point smaller, as desktop apps do.
  double _size(double touch) => formFactor == MochiFormFactor.desktop ? touch - 1 : touch;

  TextStyle get largeTitle => _base.copyWith(fontSize: _size(28), fontWeight: FontWeight.w800, height: 1.15, color: palette.ink);
  TextStyle get title3 => _base.copyWith(fontSize: _size(19), fontWeight: FontWeight.w700, height: 1.25, color: palette.ink);
  TextStyle get headline => _base.copyWith(fontSize: _size(16), fontWeight: FontWeight.w600, height: 1.3, color: palette.ink);
  TextStyle get body => _base.copyWith(fontSize: _size(15), fontWeight: FontWeight.w400, height: 1.35, color: palette.ink);
  TextStyle get subheadline => _base.copyWith(fontSize: _size(14), fontWeight: FontWeight.w400, height: 1.35, color: palette.ink);
  TextStyle get footnote => _base.copyWith(fontSize: _size(13), fontWeight: FontWeight.w400, height: 1.35, color: palette.inkSecondary);
  TextStyle get caption => _base.copyWith(fontSize: _size(12), fontWeight: FontWeight.w400, height: 1.3, color: palette.inkSecondary);

  /// Button labels.
  TextStyle get label => _base.copyWith(fontSize: _size(15), fontWeight: FontWeight.w600, height: 1.2);
}

extension MochiThemeOf on BuildContext {
  MochiPalette get palette => Theme.of(this).extension<MochiPalette>() ?? MochiPalette.light;

  MochiFormFactor get formFactor => Theme.of(this).extension<MochiFormFactorTheme>()?.formFactor ?? MochiFormFactor.touch;

  MochiType get type => MochiType(palette, formFactor: formFactor);
}

/// Which form factor a theme was built for (read with `context.formFactor`).
@immutable
class MochiFormFactorTheme extends ThemeExtension<MochiFormFactorTheme> {
  const MochiFormFactorTheme(this.formFactor);

  final MochiFormFactor formFactor;

  @override
  MochiFormFactorTheme copyWith({MochiFormFactor? formFactor}) => MochiFormFactorTheme(formFactor ?? this.formFactor);

  @override
  MochiFormFactorTheme lerp(MochiFormFactorTheme? other, double t) => t < 0.5 ? this : (other ?? this);
}

/// The Material theme for [brightness]. [formFactor] `desktop`: 36 px controls, a 2 px focus ring in
/// [MochiPalette.focus] on every Material control, hover colours, always-visible scrollbars.
ThemeData mochiTheme(Brightness brightness, {MochiFormFactor formFactor = MochiFormFactor.touch}) {
  final p = brightness == Brightness.dark ? MochiPalette.dark : MochiPalette.light;
  final type = MochiType(p, formFactor: formFactor);
  final desktop = formFactor == MochiFormFactor.desktop;
  final target = desktop ? 36.0 : 48.0;
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
  final focusSide = BorderSide(color: p.focus, width: 2, strokeAlign: BorderSide.strokeAlignOutside);
  OutlinedBorder stadium(Set<WidgetState> states) =>
      StadiumBorder(side: states.contains(WidgetState.focused) ? focusSide : BorderSide.none);
  final shape = WidgetStateProperty.resolveWith<OutlinedBorder>(stadium);
  final minimum = WidgetStateProperty.all(Size(target, target));
  final label = WidgetStateProperty.all(type.label);
  final padding = WidgetStateProperty.all(EdgeInsets.symmetric(horizontal: desktop ? 16 : 20));
  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: mochiFontFamily,
    extensions: [p, MochiFormFactorTheme(formFactor)],
    scaffoldBackgroundColor: p.backgroundTop,
    canvasColor: p.surface,
    materialTapTargetSize: desktop ? MaterialTapTargetSize.shrinkWrap : MaterialTapTargetSize.padded,
    visualDensity: desktop ? VisualDensity.compact : VisualDensity.standard,
    focusColor: p.focus.withValues(alpha: 0.18),
    hoverColor: p.tint.withValues(alpha: 0.06),
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
      style: ButtonStyle(shape: shape, minimumSize: minimum, padding: padding, textStyle: label),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: shape,
        minimumSize: minimum,
        padding: padding,
        foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? p.inkSecondary : p.tint),
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused) ? focusSide : BorderSide(color: p.stroke, width: 1.5),
        ),
        textStyle: label,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(shape: shape, minimumSize: minimum, foregroundColor: WidgetStateProperty.all(p.tint), textStyle: label),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: minimum,
        shape: WidgetStateProperty.resolveWith(
          (states) => CircleBorder(side: states.contains(WidgetState.focused) ? focusSide : BorderSide.none),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused) ? p.focus : null),
    ),
    dividerTheme: DividerThemeData(color: p.stroke, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.ink,
      contentTextStyle: type.subheadline.copyWith(color: p.surface),
      actionTextColor: p.isDark ? MochiPalette.light.tint : MochiPalette.dark.tint,
    ),
    listTileTheme: ListTileThemeData(iconColor: p.tint, textColor: p.ink, titleTextStyle: type.body, minVerticalPadding: desktop ? 6 : 12),
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
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.inner)),
        borderSide: BorderSide(color: p.focus, width: 2),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: Space.m, vertical: desktop ? 10 : 14),
      hintStyle: type.body.copyWith(color: p.inkSecondary),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.tint),
    tooltipTheme: TooltipThemeData(
      textStyle: type.footnote.copyWith(color: p.surface),
      waitDuration: const Duration(milliseconds: 500),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbVisibility: WidgetStateProperty.all(desktop),
      thumbColor: WidgetStateProperty.all(p.inkSecondary.withValues(alpha: 0.45)),
      radius: const Radius.circular(8),
    ),
  );
}
