import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_ui/mochi_ui.dart';

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

      test('the focus ring is at least 3:1 against everything it surrounds', () {
        for (final MapEntry(key: backgroundName, value: background) in backgrounds.entries) {
          expect(contrast(p.focus, background), greaterThanOrEqualTo(3), reason: 'focus on $backgroundName');
        }
      });

      test('filled buttons: their label on terracotta is at least 4.5:1', () {
        expect(contrast(p.onTint, p.tint), greaterThanOrEqualTo(4.5));
      });
    });
  }

  test('Nunito everywhere, in both form factors', () {
    for (final formFactor in MochiFormFactor.values) {
      for (final brightness in Brightness.values) {
        final theme = mochiTheme(brightness, formFactor: formFactor);
        final styles = [
          theme.textTheme.headlineMedium,
          theme.textTheme.titleLarge,
          theme.textTheme.titleMedium,
          theme.textTheme.bodyLarge,
          theme.textTheme.bodyMedium,
          theme.textTheme.bodySmall,
          theme.textTheme.labelLarge,
          theme.filledButtonTheme.style?.textStyle?.resolve({}),
        ];
        for (final style in styles) {
          expect(style?.fontFamily, mochiFontFamily);
        }
        expect(theme.extension<MochiFormFactorTheme>()?.formFactor, formFactor);
      }
    }
  });

  testWidgets('ClayPress works from the keyboard and shows a focus ring', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: mochiTheme(Brightness.light, formFactor: MochiFormFactor.desktop),
        home: Scaffold(
          body: Center(
            child: ClayPress(onTap: () => taps++, semanticLabel: 'Pet Mochi', child: const SizedBox(width: 80, height: 40)),
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Pet Mochi'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final ring = tester.widget<DecoratedBox>(find.descendant(of: find.byType(ClayPress), matching: find.byType(DecoratedBox)).first);
    expect((ring.decoration as BoxDecoration).border, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, 2);
    await tester.tap(find.byType(ClayPress));
    expect(taps, 3);
  });

  test('relative times', () {
    final now = DateTime(2026, 11, 5, 12);
    double ago(Duration d) => now.subtract(d).millisecondsSinceEpoch / 1000;
    expect(relativeTime(ago(const Duration(seconds: 10)), now: now), 'just now');
    expect(relativeTime(ago(const Duration(minutes: 5)), now: now), '5 min ago');
    expect(relativeTime(ago(const Duration(hours: 2)), now: now), '2 hours ago');
    expect(relativeTime(ago(const Duration(days: 1)), now: now), 'yesterday');
  });
}
