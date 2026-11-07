// Global shortcuts (docs/SPRINT_2.md W4): reading and writing combinations, the defaults (the Mac's ⌃⌥⌘P and ⌥Space,
// moved where Windows lets them be), the conflicts Settings refuses, registering with Windows (one another app has is
// reported, recording lets Mochi's own go), what each does, and Settings' recorder.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/hotkeys.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart';
import 'package:mochi_desktop/src/ui/settings/shortcut_row.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

final DateTime noon = DateTime(2026, 11, 7, 12);

void main() {
  group('Combinations', () {
    test('labels in Windows’ order, read back in any spelling', () {
      expect(Hotkey.petDefault.label, 'Ctrl+Alt+Win+P');
      expect(Hotkey.askDefault.label, 'Ctrl+Alt+Space');
      expect(Hotkey.petDefault.modifiers, 2 | 1 | 8);
      expect(Hotkey.parse('ctrl+alt+win+p'), Hotkey.petDefault);
      expect(Hotkey.parse('Control + Alt + Space'), Hotkey.askDefault);
      expect(Hotkey.parse('Windows+Shift+F5'), const Hotkey(0x74, win: true, shift: true));
      expect(Hotkey.parse('Ctrl+Alt+/'), const Hotkey(0xBF, ctrl: true, alt: true));
      for (final hotkey in [Hotkey.petDefault, Hotkey.askDefault, const Hotkey(0x28, ctrl: true, alt: true, shift: true)]) {
        expect(Hotkey.parse(hotkey.label), hotkey, reason: hotkey.label);
      }
      expect(Hotkey.parse('Hyper+P'), isNull);
      expect(Hotkey.parse('Ctrl+Alt+Banana'), isNull);
      expect(Hotkey.parse(''), isNull);
      expect(Hotkey.petDefault.keys, ['Ctrl', 'Alt', 'Win', 'P']);
    });

    test('Flutter’s keys become Windows’ key codes', () {
      expect(Hotkey.keyFor(LogicalKeyboardKey.keyP), 0x50);
      expect(Hotkey.keyFor(LogicalKeyboardKey.digit7), 0x37);
      expect(Hotkey.keyFor(LogicalKeyboardKey.f12), 0x7B);
      expect(Hotkey.keyFor(LogicalKeyboardKey.space), 0x20);
      expect(Hotkey.keyFor(LogicalKeyboardKey.controlLeft), isNull);
      expect(Hotkey.isModifier(LogicalKeyboardKey.metaLeft), isTrue);
      expect(Hotkey.isModifier(LogicalKeyboardKey.keyA), isFalse);
    });

    test('saved as text; "none" turns a shortcut off; a missing one is the default', () {
      final settings = DesktopSettings(MemorySettingsDocument(), clock: () => noon)
        ..setShortcut(MochiShortcut.ask, const Hotkey(0x4B, ctrl: true, alt: true))
        ..setShortcut(MochiShortcut.pet, null);
      final json = settings.toJson();
      expect((json['askShortcut'], json['petShortcut']), ('Ctrl+Alt+K', 'none'));
      final again = DesktopSettings(MemorySettingsDocument(json));
      expect((again.shortcut(MochiShortcut.ask), again.shortcut(MochiShortcut.pet)), (const Hotkey(0x4B, ctrl: true, alt: true), null));
      final old = DesktopSettings(MemorySettingsDocument({'v': 3}));
      expect((old.shortcut(MochiShortcut.pet), old.shortcut(MochiShortcut.ask)), (Hotkey.petDefault, Hotkey.askDefault));
    });
  });

  group('Conflicts', () {
    String? problem(String text, {MochiShortcut shortcut = MochiShortcut.ask, Hotkey? other}) =>
        HotkeyConflicts.problem(Hotkey.parse(text)!, shortcut: shortcut, other: other);

    test('the defaults are free', () {
      expect(problem('Ctrl+Alt+Win+P', shortcut: MochiShortcut.pet, other: Hotkey.askDefault), isNull);
      expect(problem('Ctrl+Alt+Space', other: Hotkey.petDefault), isNull);
    });

    test('Alt+Space is Windows’ window menu: Ctrl+Alt+Space is suggested', () {
      expect(problem('Alt+Space'), 'Alt+Space opens the window menu in Windows (and PowerToys Run). Try Ctrl+Alt+Space.');
    });

    test('what Windows keeps, what belongs to the app you’re in, and Mochi’s other shortcut', () {
      expect(problem('Win+Shift+S'), contains('Snipping Tool'));
      expect(problem('Ctrl+Shift+Esc'), contains('Task Manager'));
      expect(problem('Win+Ctrl+Right'), contains('virtual desktops'));
      expect(problem('Win+L'), 'Win with one key belongs to Windows. Add Ctrl, Alt or Shift.');
      expect(problem('Win+Shift+3'), contains('taskbar'));
      expect(problem('Ctrl+C'), contains('belongs to the app you’re in'));
      expect(problem('Ctrl+Shift+M'), contains('belongs to the app you’re in'));
      expect(problem('Alt+M'), contains('belongs to the app you’re in'));
      expect(problem('Ctrl+Alt+Win+P', other: Hotkey.petDefault), 'Ctrl+Alt+Win+P is already Mochi’s shortcut for “Show or hide the desktop pet”.');
      expect(problem('Ctrl+Alt+M'), isNull);
      expect(problem('Win+Alt+M'), isNull);
    });
  });

  group('Registered with Windows', () {
    late TestDesktop t;
    setUp(() => t = TestDesktop.make(clock: () => noon));
    tearDown(() => t.dispose());

    test('both at start; a change re-registers; turned off lets it go', () async {
      await t.desktop.hotkeys.start();
      expect(t.hotkeys.registered, {1: Hotkey.petDefault, 2: Hotkey.askDefault});
      t.desktop.settings.setShortcut(MochiShortcut.ask, const Hotkey(0x4B, ctrl: true, alt: true));
      await t.desktop.hotkeys.apply();
      expect(t.hotkeys.registered[2], const Hotkey(0x4B, ctrl: true, alt: true));
      t.desktop.settings.setShortcut(MochiShortcut.pet, null);
      await t.desktop.hotkeys.apply();
      expect(t.hotkeys.registered.containsKey(1), isFalse);
    });

    test('one another app already has is reported, and works again once changed', () async {
      t.hotkeys.taken.add(Hotkey.askDefault);
      await t.desktop.hotkeys.start();
      expect(t.desktop.hotkeys.problem(MochiShortcut.ask), 'Ctrl+Alt+Space is already used by another app. Pick another shortcut.');
      expect(t.desktop.hotkeys.problem(MochiShortcut.pet), isNull);
      t.desktop.settings.setShortcut(MochiShortcut.ask, const Hotkey(0x4D, ctrl: true, alt: true));
      await t.desktop.hotkeys.apply();
      expect(t.desktop.hotkeys.problem(MochiShortcut.ask), isNull);
      expect(t.hotkeys.registered[2], const Hotkey(0x4D, ctrl: true, alt: true));
    });

    test('while Settings records a combination, Mochi’s own are let go', () async {
      await t.desktop.hotkeys.start();
      await t.desktop.hotkeys.suspend();
      expect(t.hotkeys.registered, isEmpty);
      t.hotkeys.press(MochiShortcut.pet);
      await t.desktop.hotkeys.resume();
      expect(t.hotkeys.registered.length, 2);
    });

    testWidgets('pressed: the pet shows or hides; Ask Mochi opens the question box, and closes it again', (tester) async {
      await tester.runAsync(t.desktop.start);
      await tester.pumpWidget(DesktopApp(desktop: t.desktop, shell: FakeShell(), library: Future<PoseLibrary?>.value()));
      await tester.pump(const Duration(milliseconds: 100));
      final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
      t.hotkeys.press(MochiShortcut.pet);
      await tester.pump(const Duration(milliseconds: 100));
      expect(t.desktop.settings.showPet, isFalse);
      expect(state.surface, Surface.hidden);
      t.hotkeys.press(MochiShortcut.pet);
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.surface, Surface.pet);
      t.hotkeys.press(MochiShortcut.ask);
      await tester.pump(const Duration(milliseconds: 300));
      expect((state.surface, state.page), (Surface.main, MainPage.home));
      t.hotkeys.press(MochiShortcut.ask);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.surface, Surface.pet);
    });
  });

  group('Settings’ recorder', () {
    late TestDesktop t;
    setUp(() => t = TestDesktop.make(clock: () => noon));
    tearDown(() => t.dispose());

    Future<void> open(WidgetTester tester, SettingsTab pane, {double textScale = 1}) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.runAsync(t.desktop.start);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: pane,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> press(WidgetTester tester, List<LogicalKeyboardKey> modifiers, LogicalKeyboardKey key) async {
      for (final modifier in modifiers) {
        await tester.sendKeyDownEvent(modifier);
      }
      await tester.sendKeyEvent(key);
      for (final modifier in modifiers.reversed) {
        await tester.sendKeyUpEvent(modifier);
      }
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('Assistant: Change… records a new one; Alt+Space is refused with the reason; Turn Off and back', (tester) async {
      await open(tester, SettingsTab.assistant);
      expect(find.text('Ctrl'), findsWidgets);
      expect(find.textContaining('or press Ctrl+Alt+Space anywhere'), findsOneWidget);
      final row = find.byWidgetPredicate((widget) => widget is ShortcutRow && widget.shortcut == MochiShortcut.ask);
      Future<void> change() async {
        final button = find.descendant(of: row, matching: find.text('Change…'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump(const Duration(milliseconds: 100));
      }

      await change();
      expect(find.text('Press the new shortcut… (Esc cancels)'), findsOneWidget);
      expect(t.hotkeys.registered, isEmpty, reason: 'let go while recording');
      await press(tester, [LogicalKeyboardKey.altLeft], LogicalKeyboardKey.space);
      expect(find.text('Alt+Space opens the window menu in Windows (and PowerToys Run). Try Ctrl+Alt+Space.'), findsOneWidget);
      expect(t.desktop.settings.shortcut(MochiShortcut.ask), Hotkey.askDefault, reason: 'kept');
      expect(t.hotkeys.registered.length, 2, reason: 'back once recording ends');

      await change();
      await press(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.altLeft], LogicalKeyboardKey.keyK);
      expect(t.desktop.settings.shortcut(MochiShortcut.ask), const Hotkey(0x4B, ctrl: true, alt: true));
      expect(t.document.json!['askShortcut'], 'Ctrl+Alt+K');
      await tester.pump(const Duration(milliseconds: 100));
      expect(t.hotkeys.registered[2], const Hotkey(0x4B, ctrl: true, alt: true));

      await change();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Press the new shortcut… (Esc cancels)'), findsNothing);

      await tester.ensureVisible(find.descendant(of: row, matching: find.text('Turn Off')));
      await tester.tap(find.descendant(of: row, matching: find.text('Turn Off')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(t.desktop.settings.shortcut(MochiShortcut.ask), isNull);
      expect(find.descendant(of: row, matching: find.text('None')), findsOneWidget);
      await tester.ensureVisible(find.descendant(of: row, matching: find.text('Use Ctrl+Alt+Space')));
      await tester.tap(find.descendant(of: row, matching: find.text('Use Ctrl+Alt+Space')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(t.desktop.settings.shortcut(MochiShortcut.ask), Hotkey.askDefault);
    });

    testWidgets('Desktop Pet: a combination another app has is reported; Mochi’s other one is refused', (tester) async {
      t.hotkeys.taken.add(Hotkey.petDefault);
      await open(tester, SettingsTab.desktop);
      expect(find.text('Ctrl+Alt+Win+P is already used by another app. Pick another shortcut.'), findsOneWidget);
      expect(find.textContaining('Show or hide Mochi any time with Ctrl+Alt+Win+P'), findsOneWidget);
      final change = find.text('Change…');
      await tester.ensureVisible(change);
      await tester.tap(change);
      await tester.pump(const Duration(milliseconds: 100));
      await press(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.altLeft], LogicalKeyboardKey.space);
      expect(find.text('Ctrl+Alt+Space is already Mochi’s shortcut for “Ask Mochi”.'), findsOneWidget);
    });

    testWidgets('the recorder fits at 2× text, in the dark', (tester) async {
      t.desktop.settings.themeMode = ThemeMode.dark;
      await open(tester, SettingsTab.desktop, textScale: 2);
      await tester.ensureVisible(find.text('Change…'));
      await tester.tap(find.text('Change…'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.text(SoonRow.tag), findsWidgets, reason: 'the pane’s other Mac features');
    });

    testWidgets('where shortcuts can’t be registered (the macOS build), the buttons are off and it says so', (tester) async {
      t.hotkeys.supported = false;
      await open(tester, SettingsTab.assistant);
      expect(find.text('Global shortcuts work in Mochi for Windows.'), findsOneWidget);
      final button = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Change…'));
      expect(button.onPressed, isNull);
    });
  });
}
