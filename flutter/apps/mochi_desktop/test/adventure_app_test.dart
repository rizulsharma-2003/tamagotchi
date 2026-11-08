// Explore the desktop in the app (docs/SPRINT_2.md W19): Settings › Fun › Adventures (the Mac's section, its words), the
// tray menu's "Explore the Desktop" item, and Ask Mochi's "go explore" and "come home". The adventure itself is in
// adventure_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/quick_commands.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

void main() {
  late TestDesktop t;
  late FakeShell shell;

  setUp(() {
    t = TestDesktop.make();
    shell = FakeShell();
  });
  tearDown(() => t.dispose());

  Future<void> app(WidgetTester tester, {Surface surface = Surface.main, MainPage page = MainPage.settings, SettingsTab? pane = SettingsTab.fun}) async {
    tester.view.physicalSize = SurfaceSizes.settings;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      DesktopApp(desktop: t.desktop, shell: shell, initialSurface: surface, initialPage: page, initialPane: pane, library: Future<PoseLibrary?>.value()),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Settings › Fun › Adventures: the Mac’s words, the toggle, “Sets off by itself”, Explore Now', (tester) async {
    await app(tester);
    final settings = t.desktop.settings;
    final adventures = find.text('Adventures');
    await tester.ensureVisible(adventures);
    expect(adventures, findsOneWidget);
    expect(find.text('Mochi explores the desktop'), findsOneWidget);
    expect(find.text('Sets off by itself'), findsOneWidget);
    expect(
      find.text(
        'Drag Mochi up off the taskbar, or choose Explore. Out there it walks along window tops, sits on the taskbar and climbs the '
        'screen’s edge. Only where windows are is read — never what they show — and only while Mochi is out.',
      ),
      findsOneWidget,
    );
    expect(find.text('Not on Windows yet'), findsNothing, reason: 'no “from the Mac” placeholder any more');
    // Never, Rarely, Sometimes (on at first).
    final sometimes = find.widgetWithText(ChoiceChip, 'Sometimes');
    await tester.ensureVisible(sometimes);
    expect(tester.widget<ChoiceChip>(sometimes).selected, isTrue);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Rarely'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(settings.adventure.spontaneous, w.AdventureFrequency.rarely);
    expect((t.document.json!['adventure'] as Map)['spontaneous'], 'rarely');
    // Explore Now is there; off, the frequency and the button rest.
    final explore = find.widgetWithText(OutlinedButton, 'Explore Now');
    await tester.ensureVisible(explore);
    expect(tester.widget<OutlinedButton>(explore).onPressed, isNotNull);
    await tester.tap(find.text('Mochi explores the desktop'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(settings.adventure.enabled, isFalse);
    expect((t.document.json!['adventure'] as Map)['enabled'], false);
    expect(tester.widget<OutlinedButton>(explore).onPressed, isNull);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Never')).onSelected, isNull, reason: 'disabled while the toggle is off');
  });

  testWidgets('the tray menu: “Explore the Desktop”, and not while Adventures are off', (tester) async {
    await app(tester, surface: Surface.pet, page: MainPage.home, pane: null);
    expect(shell.trayExplore.last, 'Explore the Desktop');
    t.desktop.settings.adventure = const w.AdventureSettings(enabled: false);
    await tester.pump();
    expect(shell.trayExplore.last, isNull);
    t.desktop.settings.adventure = const w.AdventureSettings();
    await tester.pump();
    expect(shell.trayExplore.last, 'Explore the Desktop');
    expect(NativeShell.trayItems(style: t.desktop.settings.petStyle, explore: 'Bring Mochi Home').any((item) => item.label == 'Bring Mochi Home'), isTrue);
    expect(NativeShell.trayItems(style: t.desktop.settings.petStyle).any((item) => item.key == ShellAction.explore.name), isFalse);
  });

  testWidgets('Ask Mochi: “go explore” and “come home” work now', (tester) async {
    await app(tester, surface: Surface.main, page: MainPage.home, pane: null);
    final ask = t.desktop.ask;
    expect((await ask.perform(SimpleCommand.comeHome)).text, 'Mochi is already home.');
    final off = (await ask.perform(SimpleCommand.explore));
    expect(off.ok, isTrue);
    expect(off.text, 'Off to explore your desktop!', reason: 'from Mochi’s window it goes back to the taskbar first');
    t.desktop.settings.adventure = const w.AdventureSettings(enabled: false);
    final no = await ask.perform(SimpleCommand.explore);
    expect(no.ok, isFalse);
    expect(no.text, contains('Settings › Fun'));
  });
}
