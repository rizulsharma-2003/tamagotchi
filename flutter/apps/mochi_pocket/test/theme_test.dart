import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_pocket/src/theme.dart';

/// WCAG contrast ratio.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  for (final (name, p) in [('light', MochiPalette.light), ('dark', MochiPalette.dark)]) {
    group('$name palette', () {
      final backgrounds = {
        'surface': p.surface,
        'sunken': p.sunken,
        'backgroundTop': p.backgroundTop,
        'backgroundBottom': p.backgroundBottom,
      };

      test('text colours are at least 4.5:1 on cards, wells and the backdrop', () {
        final text = {
          'ink': p.ink,
          'inkSecondary': p.inkSecondary,
          'tint': p.tint,
          'success': p.success,
          'warning': p.warning,
          'danger': p.danger,
        };
        for (final MapEntry(key: textName, value: color) in text.entries) {
          for (final MapEntry(key: backgroundName, value: background) in backgrounds.entries) {
            expect(contrast(color, background), greaterThanOrEqualTo(4.5), reason: '$textName on $backgroundName');
          }
        }
      });

      test('Notion indigo (row titles stay ink; the tile icon is the only indigo) reads on cards and wells', () {
        expect(contrast(p.indigo, p.surface), greaterThanOrEqualTo(4.5));
        expect(contrast(p.indigo, p.sunken), greaterThanOrEqualTo(4.5));
      });

      test('filled buttons: their label on terracotta is at least 4.5:1', () {
        expect(contrast(p.onTint, p.tint), greaterThanOrEqualTo(4.5));
      });

      test('icon-only colours (VIP star, Pet, Play) are at least 3:1 on cards', () {
        for (final color in [p.vip, p.pet, p.play]) {
          expect(contrast(color, p.surface), greaterThanOrEqualTo(3));
        }
      });
    });
  }

  test('Nunito everywhere: every theme text style names the bundled family', () {
    for (final brightness in Brightness.values) {
      final theme = mochiTheme(brightness);
      final styles = [
        theme.textTheme.headlineMedium,
        theme.textTheme.titleLarge,
        theme.textTheme.titleMedium,
        theme.textTheme.bodyLarge,
        theme.textTheme.bodyMedium,
        theme.textTheme.bodySmall,
        theme.textTheme.labelLarge,
        theme.appBarTheme.titleTextStyle,
        theme.filledButtonTheme.style?.textStyle?.resolve({}),
        theme.outlinedButtonTheme.style?.textStyle?.resolve({}),
        theme.textButtonTheme.style?.textStyle?.resolve({}),
      ];
      for (final style in styles) {
        expect(style?.fontFamily, mochiFont);
      }
    }
  });

  test('weights mirror the iPhone: heavy title, bold section titles, semibold headlines, regular text', () {
    final type = MochiType(MochiPalette.light);
    expect(type.largeTitle.fontWeight, FontWeight.w800);
    expect(type.title3.fontWeight, FontWeight.w700);
    expect(type.headline.fontWeight, FontWeight.w600);
    for (final style in [type.body, type.subheadline, type.footnote, type.caption]) {
      expect(style.fontWeight, FontWeight.w400);
    }
  });
}
