// Mischief, the Windows extras' frame (docs/SPRINT_2.md, "crazier than the Mac"): the master switch (off at first) and
// each extra's, saved under `mischief`; the one place that decides whether an extra may run now (MischiefGate), with
// every rule; and Settings › Mischief (light and dark, 1× and 2× text in settings_test.dart; the keyboard and the screen
// reader here).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show QuietHours;
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

void main() {
  group('Settings', () {
    test('off at first; each extra on once Mischief is on; saved under `mischief` and read back', () {
      final document = MemorySettingsDocument();
      final settings = DesktopSettings(document);
      expect(settings.mischief.enabled, isFalse);
      for (final extra in MischiefExtra.values) {
        expect(settings.mischief.on(extra), isTrue);
        expect(settings.mischief.allows(extra), isFalse, reason: 'the master switch is off');
      }
      settings.mischief = settings.mischief.copyWith(enabled: true).withExtra(MischiefExtra.cursorBuddy, false);
      expect(document.json!['mischief'], {
        'enabled': true,
        'celebrations': true,
        'cursorBuddy': false,
        'stickyNotes': true,
        'roamScreens': true,
      });
      expect(document.json!['v'], 8);
      final again = DesktopSettings(MemorySettingsDocument(document.json));
      expect(again.mischief, settings.mischief);
      expect(again.mischief.allows(MischiefExtra.cursorBuddy), isFalse);
      expect(again.mischief.allows(MischiefExtra.celebrations), isTrue);
    });

    test('a damaged or older file: Mischief off, extras on; Reset turns it off again', () {
      expect(DesktopSettings(MemorySettingsDocument({'mischief': 'yes'})).mischief, const MischiefSettings());
      expect(DesktopSettings(MemorySettingsDocument({'mischief': {'enabled': 1, 'cursorBuddy': 'no'}})).mischief, const MischiefSettings());
      final settings = DesktopSettings(MemorySettingsDocument({'mischief': {'enabled': true}}));
      expect(settings.mischief.enabled, isTrue);
      settings.reset();
      expect(settings.mischief.enabled, isFalse);
    });

    test('setting the same switches again saves nothing and tells nobody', () {
      final settings = DesktopSettings(MemorySettingsDocument());
      var told = 0;
      settings.addListener(() => told++);
      settings.mischief = const MischiefSettings();
      settings.mischief = const MischiefSettings(extras: {MischiefExtra.stickyNotes: true});
      expect(told, 0);
    });
  });

  group('May mischief run now', () {
    late DesktopSettings settings;
    late PcRhythm rhythm;
    late SystemMotion motion;
    late MischiefGate gate;
    var fullScreen = false;
    var focusing = false;
    var now = DateTime(2026, 11, 8, 15);

    setUp(() {
      fullScreen = false;
      focusing = false;
      now = DateTime(2026, 11, 8, 15);
      settings = DesktopSettings(MemorySettingsDocument());
      rhythm = PcRhythm(settings: settings)..report(const SystemActivity(idleSeconds: 2));
      motion = SystemMotion(read: () => false);
      gate = MischiefGate(
        settings: settings,
        rhythm: rhythm,
        motion: motion,
        supported: true,
        fullScreen: () => fullScreen,
        focusing: () => focusing,
        clock: () => now,
        checkEvery: const Duration(milliseconds: 10),
      )..start();
    });

    tearDown(() {
      gate.dispose();
      rhythm.dispose();
      motion.dispose();
    });

    void allOn() => settings.mischief = const MischiefSettings(enabled: true);

    test('only with the master switch and the extra’s own switch on', () {
      expect(gate.why(MischiefExtra.cursorBuddy), MischiefPause.off);
      allOn();
      for (final extra in MischiefExtra.values) {
        expect(gate.may(extra), isTrue, reason: extra.name);
      }
      settings.mischief = settings.mischief.withExtra(MischiefExtra.cursorBuddy, false);
      expect(gate.why(MischiefExtra.cursorBuddy), MischiefPause.extraOff);
      expect(gate.may(MischiefExtra.stickyNotes), isTrue);
      expect(gate.whyAll, isNull, reason: 'one extra off pauses nothing else');
    });

    test('never without the native stage (the macOS build)', () {
      final none = MischiefGate(settings: settings, rhythm: rhythm, motion: motion)..start();
      allOn();
      expect(none.why(MischiefExtra.celebrations), MischiefPause.unsupported);
      expect(none.checking, isFalse);
      none.dispose();
    });

    test('still while a full-screen app, a game or a presentation has the screen, and again after', () async {
      allOn();
      fullScreen = true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      for (final extra in MischiefExtra.values) {
        expect(gate.why(extra), MischiefPause.fullScreen, reason: extra.name);
      }
      expect(gate.whyAll, MischiefPause.fullScreen);
      fullScreen = false;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(gate.may(MischiefExtra.cursorBuddy), isTrue);
    });

    test('still for quiet hours and quiet mode, and while reactions are paused', () {
      allOn();
      settings.quietHours = const QuietHours(enabled: true, startMinute: 14 * 60, endMinute: 16 * 60);
      expect(gate.why(MischiefExtra.stickyNotes), MischiefPause.quiet);
      now = DateTime(2026, 11, 8, 16, 1);
      gate.check();
      expect(gate.may(MischiefExtra.stickyNotes), isTrue, reason: 'quiet hours are over');
      settings.quietMode = true;
      expect(gate.why(MischiefExtra.celebrations), MischiefPause.quiet);
      settings.quietMode = false;
      settings.pauseReactions = true;
      expect(gate.why(MischiefExtra.roamScreens), MischiefPause.paused);
    });

    test('moving extras rest while you focus and with animation effects off; notes still come', () {
      allOn();
      focusing = true;
      gate.check();
      expect(gate.why(MischiefExtra.cursorBuddy), MischiefPause.focusing);
      expect(gate.why(MischiefExtra.celebrations), MischiefPause.focusing);
      expect(gate.may(MischiefExtra.stickyNotes), isTrue);
      focusing = false;
      motion.value = true;
      expect(gate.why(MischiefExtra.roamScreens), MischiefPause.calm);
      expect(gate.may(MischiefExtra.stickyNotes), isTrue);
      expect(gate.whyAll, isNull, reason: 'notes can still come');
    });

    test('nothing while nobody can see the screen, and no timer either; back when it is', () {
      allOn();
      expect(gate.checking, isTrue);
      rhythm.report(const SystemActivity(idleSeconds: 400, displaysAsleep: true));
      for (final extra in MischiefExtra.values) {
        expect(gate.why(extra), MischiefPause.unseen);
      }
      expect(gate.checking, isFalse, reason: 'no timer while the screen is off');
      rhythm.report(const SystemActivity(idleSeconds: 0));
      expect(gate.may(MischiefExtra.celebrations), isTrue);
      expect(gate.checking, isTrue);
    });

    test('no timer while Mischief is off; listeners hear only about changes', () async {
      expect(gate.checking, isFalse);
      var told = 0;
      gate.addListener(() => told++);
      allOn();
      expect(told, 1);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(told, 1, reason: 'the regular look found nothing new');
      settings.mischief = settings.mischief.copyWith(enabled: false);
      expect(told, 2);
      expect(gate.checking, isFalse);
    });

    test('the rules in order: off before the screen, the screen before full screen, full screen before quiet hours', () {
      settings.quietMode = true;
      fullScreen = true;
      rhythm.report(const SystemActivity(idleSeconds: 400, displaysAsleep: true));
      expect(gate.why(MischiefExtra.cursorBuddy), MischiefPause.off);
      allOn();
      expect(gate.why(MischiefExtra.cursorBuddy), MischiefPause.unseen);
      rhythm.report(const SystemActivity(idleSeconds: 1));
      expect(gate.why(MischiefExtra.cursorBuddy), MischiefPause.fullScreen);
      fullScreen = false;
      gate.check();
      expect(gate.why(MischiefExtra.cursorBuddy), MischiefPause.quiet);
    });
  });

  group('Settings › Mischief', () {
    late TestDesktop t;
    late FakeShell shell;

    setUp(() {
      t = TestDesktop.make();
      shell = FakeShell();
    });

    tearDown(() => t.dispose());

    Future<void> open(WidgetTester tester, {double textScale = 1}) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      t.desktop.mischief.start();
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: shell,
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.mischief,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// The gate's regular look stops with the test (the desktop is disposed after the test's timers are checked).
    Future<void> done(WidgetTester tester) async {
      t.desktop.mischief.stop();
      await tester.pumpWidget(const SizedBox());
    }

    Finder toggle(String title) => find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first;

    testWidgets('the master switch is off at first and the extras wait for it; each says what it does', (tester) async {
      await open(tester);
      expect(find.text('Let Mochi make mischief'), findsOneWidget);
      expect(find.text(MischiefExtra.roamScreens.title), findsNothing, reason: 'not built yet: no dead switch');
      for (final extra in MischiefExtra.available) {
        expect(find.text(extra.title), findsOneWidget);
        expect(find.text(extra.detail), findsOneWidget);
      }
      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches.first.value, isFalse);
      expect(switches.skip(1).every((s) => s.onChanged == null), isTrue, reason: 'the extras wait for the master switch');
      await tester.tap(toggle('Let Mochi make mischief'));
      await tester.pump();
      expect(t.desktop.settings.mischief.enabled, isTrue);
      await tester.tap(toggle(MischiefExtra.cursorBuddy.title));
      await tester.pump();
      expect(t.desktop.settings.mischief.on(MischiefExtra.cursorBuddy), isFalse);
      expect(find.textContaining('never takes your keyboard or pointer'), findsOneWidget);
      await done(tester);
    });

    testWidgets('why it’s resting: the screen is held by a full-screen app (once, above), or only one extra is calm', (tester) async {
      await open(tester);
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      t.desktop.motion.value = true;
      await tester.pump();
      expect(find.text('${MischiefExtra.cursorBuddy.detail}\n${MischiefPause.calm.note('Mochi')}'), findsOneWidget);
      expect(find.text(MischiefExtra.stickyNotes.detail), findsOneWidget, reason: 'notes still come');
      t.desktop.motion.value = false;
      t.desktop.settings.quietMode = true;
      await tester.pump();
      expect(find.text(MischiefPause.quiet.note('Mochi')), findsOneWidget, reason: 'said once, above the extras');
      expect(find.text(MischiefExtra.cursorBuddy.detail), findsOneWidget);
      await done(tester);
    });

    testWidgets('the keyboard: Tab reaches each switch and Space flips it', (tester) async {
      await open(tester);
      final master = find.byType(Switch).first;
      bool focusedIn(Finder finder) {
        final context = FocusManager.instance.primaryFocus?.context;
        if (context is! Element) return false;
        final target = tester.element(finder);
        var inside = context == target;
        context.visitAncestorElements((element) {
          if (element == target) inside = true;
          return !inside;
        });
        return inside;
      }

      for (var i = 0; i < 60 && !focusedIn(master); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focusedIn(master), isTrue, reason: 'Tab reaches the master switch');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(t.desktop.settings.mischief.enabled, isTrue);
      final first = find.byType(Switch).at(1);
      for (var i = 0; i < 60 && !focusedIn(first); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focusedIn(first), isTrue, reason: 'Tab reaches the first extra too');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(t.desktop.settings.mischief.on(MischiefExtra.values.first), isFalse);
      await done(tester);
    });

    testWidgets('the screen reader hears each switch with what it does, and whether it’s on', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester);
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      await tester.pump();
      for (final extra in MischiefExtra.available) {
        final node = tester.getSemantics(find.bySemanticsLabel(RegExp('^${RegExp.escape(extra.title)}'))).getSemanticsData();
        expect(node.label, contains(extra.detail));
        expect((node.flagsCollection.hasToggledState, node.flagsCollection.isToggled), (true, true));
      }
      semantics.dispose();
      await done(tester);
    });

    testWidgets('2× text: nothing overflows', (tester) async {
      await open(tester, textScale: 2);
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      t.desktop.settings.pauseReactions = true;
      await tester.pump();
      expect(tester.takeException(), isNull);
      await done(tester);
    });

  });

  group('Settings › Mischief without the native stage', () {
    late TestDesktop t;

    setUp(() => t = TestDesktop.make(stage: false));
    tearDown(() => t.dispose());

    testWidgets('the macOS build: the switches can’t be turned on, and it says why', (tester) async {
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      t.desktop.mischief.start();
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.mischief,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(MischiefPause.unsupported.note('Mochi')), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch).first).onChanged, isNull);
      t.desktop.mischief.stop();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
