// The popover (ui/popover/popover_view.dart): clicking Mochi on the taskbar opens it above where Mochi is; it shows
// the room, Claude Code's connection, the session (with a menu to choose which one Mochi follows), the result card,
// the recent events, Pet / Play / Treat, the quick switches (each one a setting, saved) and the ways on; it fits in
// light and dark at 1× and 2× text; the keyboard works; Escape or a click elsewhere closes it, and Mochi is back on
// its spot on the taskbar.

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/sessions.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/room_view.dart';
import 'package:mochi_desktop/src/ui/popover/popover_view.dart';
import 'package:mochi_desktop/src/ui/screens/home_screen.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

void main() {
  late PoseLibrary library;
  late TestDesktop t;
  late FakeShell shell;
  late FakePetWindow window;
  late FakeTaskbar taskbar;

  setUpAll(() => library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync()));

  setUp(() {
    t = TestDesktop.make(saved: hostCredentials);
    window = FakePetWindow();
    shell = FakeShell(petWindow: window);
    final reading = FakeTaskbar.bottomTaskbar();
    taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
  });

  tearDown(() => t.dispose());

  /// Two sessions (web working, api asking for permission), and one that came in late from the spool.
  void sessions() {
    final now = DateTime.now();
    final store = t.desktop.sessions;
    store
      ..apply(hook('SessionStart', session: 'a', project: 'web', at: now.subtract(const Duration(minutes: 3))))
      ..apply(hook('UserPromptSubmit', session: 'a', project: 'web', at: now.subtract(const Duration(minutes: 2))))
      ..apply(hook('PreToolUse', session: 'a', project: 'web', tool: 'Bash', toolUseId: 'b', at: now.subtract(const Duration(minutes: 1))))
      ..apply(hook('SessionStart', session: 'b', project: 'api', at: now.subtract(const Duration(minutes: 5))))
      ..apply(hook('Notification', session: 'b', project: 'api', notificationType: 'permission_prompt', at: now))
      ..apply(
        hook('PreToolUse', session: 'a', project: 'web', tool: 'Read', toolUseId: 'r', at: now.subtract(const Duration(seconds: 50))),
        delivery: Delivery.late,
      );
  }

  /// The test's view takes the window's size, as Windows would, and the transitions play out.
  Future<void> follow(WidgetTester tester, [Duration settle = const Duration(milliseconds: 800)]) async {
    await tester.pump();
    final frame = window.current!;
    tester.view.physicalSize = Size(frame.width.toDouble(), frame.height.toDouble());
    // In frames, so the transitions' vsync ticker runs.
    for (var ms = 0; ms < settle.inMilliseconds; ms += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// The app on the taskbar, then a click on Mochi: the popover. The test's view takes each form's size.
  Future<DesktopAppState> open(
    WidgetTester tester, {
    double textScale = 1,
    ThemeMode theme = ThemeMode.light,
    void Function()? then,
  }) async {
    t.desktop.settings.themeMode = theme;
    tester.view.physicalSize = const Size(64, 40);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      DesktopApp(
        desktop: t.desktop,
        shell: shell,
        taskbar: taskbar,
        library: Future.value(library),
        strollClock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        strollRandom: Random(5),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
    expect(state.stroll.onTaskbar, isTrue);
    await tester.tap(find.byType(GestureDetector).first);
    await follow(tester);
    expect(state.surface, Surface.popover);
    // News once it's open (the pet's speech bubble needs a bigger window than the test's view has).
    if (then != null) {
      then();
      await tester.pump(const Duration(milliseconds: 300));
    }
    return state;
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('everything fits (${theme.name}, ${scale.toStringAsFixed(0)}× text)', (tester) async {
        await open(tester, textScale: scale, theme: theme, then: sessions);
        expect(tester.takeException(), isNull);
        expect(Theme.of(tester.element(find.byType(PopoverView))).brightness, theme == ThemeMode.dark ? Brightness.dark : Brightness.light);
        expect(find.byType(RoomView), findsOneWidget, reason: 'the living scene');
        expect(find.textContaining('Claude Code'), findsWidgets, reason: 'the connection');
        expect(find.text('api'), findsOneWidget, reason: 'the session that needs you comes first');
        expect(find.text('2 sessions'), findsOneWidget);
        expect(find.bySemanticsLabel('needs you'), findsOneWidget);
        expect(find.text('Waiting for your permission'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('^Pet Mochi')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('^Play with Mochi')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('^Give Mochi a treat')), findsOneWidget);
        for (final label in ['Pause reactions', 'Show the desktop pet', 'Mochi on the taskbar', 'Patch on the taskbar']) {
          expect(find.bySemanticsLabel(RegExp('^$label')), findsOneWidget, reason: label);
        }
        expect(find.text('Friendship level 0'), findsOneWidget, reason: 'the Mac’s hearts (W13)');
        expect(find.bySemanticsLabel(RegExp('^Mark a milestone')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('^Games: Catch the Treats')), findsOneWidget, reason: 'the Mac’s fun row (W14)');
        expect(find.bySemanticsLabel(RegExp('^Focus: a timer Mochi naps through')), findsOneWidget, reason: 'and Focus (W15)');
        expect(find.bySemanticsLabel(RegExp('^Today’s recap')), findsOneWidget, reason: 'and Recap (W16)');
        expect(find.bySemanticsLabel(RegExp('^Decorate Mochi’s room')), findsOneWidget, reason: 'and Decorate (W18)');
        expect(find.textContaining('Sound'), findsNothing, reason: 'no sounds on Windows yet: no switch for them');
        for (final button in ['Open Mochi', 'Ask Mochi', 'Settings']) {
          expect(find.text(button), findsOneWidget);
        }
        final scrollable = find.descendant(of: find.byType(PopoverView), matching: find.byType(Scrollable)).first;
        await tester.drag(scrollable, const Offset(0, -1000));
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the session menu chooses which session Mochi follows; the recent events are only that one’s, LATE marked', (tester) async {
    await open(tester, then: sessions);
    final store = t.desktop.sessions;
    expect(store.primary!.project, 'api');
    expect(find.text('RECENT'), findsOneWidget);
    expect(find.textContaining('About to use Read'), findsNothing, reason: "web's events aren't api's");
    await tester.tap(find.byTooltip('Choose the session Mochi follows'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('web — ').last);
    await tester.pumpAndSettle();
    expect((store.pinned, store.primary!.project), ('a', 'web'));
    expect(find.text('Pinned: Mochi follows this session'), findsOneWidget);
    expect(find.text('About to use Read'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('arrived late')), findsOneWidget, reason: 'it came in from the spool');
    await tester.tap(find.byTooltip('Choose the session Mochi follows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Most relevant (automatic)').last);
    await tester.pumpAndSettle();
    expect((store.pinned, store.primary!.project), (null, 'api'));
  });

  testWidgets('a finished turn shows its result card until it is dismissed', (tester) async {
    final now = DateTime.now();
    t.desktop.sessions
      ..apply(hook('UserPromptSubmit', session: 'c', project: 'mobile', at: now.subtract(const Duration(minutes: 4))))
      ..apply(hook('Stop', session: 'c', project: 'mobile', at: now));
    await open(tester);
    expect(find.text('Turn complete · mobile'), findsOneWidget);
    expect(find.text('No build or test result was received this turn.'), findsOneWidget);
    expect(find.textContaining('Observed turn length: 4 min'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss result'));
    await tester.pump();
    expect(find.text('Turn complete · mobile'), findsNothing);
  });

  testWidgets('the switches are settings: each one is saved, and Patch’s needs him around and roaming on', (tester) async {
    await open(tester);
    final settings = t.desktop.settings;
    Future<void> flip(String label) async {
      await tester.tap(find.bySemanticsLabel(RegExp('^$label')));
      await tester.pump();
    }

    await flip('Pause reactions');
    expect((settings.pauseReactions, t.document.json!['pauseReactions']), (true, true));
    expect(find.bySemanticsLabel('paused'), findsOneWidget, reason: 'the scene says so, as on the Mac');
    await flip('Patch on the taskbar');
    expect((settings.companionOnTaskbar, t.document.json!['companionOnTaskbar']), (false, false));
    await flip('Mochi on the taskbar');
    expect((settings.roamTaskbar, t.document.json!['roamTaskbar']), (false, false));
    await flip('Patch on the taskbar');
    expect(settings.companionOnTaskbar, isFalse, reason: 'off while Mochi is off the taskbar');
    await flip('Mochi on the taskbar');
    await flip('Show the desktop pet');
    expect((settings.showPet, t.document.json!['showPet']), (false, false));
    expect(tester.state<DesktopAppState>(find.byType(DesktopApp)).surface, Surface.popover, reason: 'still open');
    final toggled = tester.getSemantics(find.bySemanticsLabel(RegExp('^Mochi on the taskbar'))).getSemanticsData().flagsCollection;
    expect((toggled.hasToggledState, toggled.isToggled), (true, true));
    settings.companionVisibility = CompanionVisibility.never;
    await tester.pump();
    settings.showPet = true;
    await tester.pump();
    final patch = tester.getSemantics(find.bySemanticsLabel(RegExp('^Patch on the taskbar'))).getSemanticsData().flagsCollection;
    expect(patch.isEnabled, isFalse, reason: 'Patch never shows');
  });

  testWidgets('the keyboard: it opens with the focus on Pet, Tab moves on, Enter and Space press, Escape closes it', (tester) async {
    final state = await open(tester);
    final settings = t.desktop.settings;
    // Pet, Play, Treat, Milestone, the fun row (Games, Focus, Recap, Decorate), then Pause.
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(settings.pauseReactions, isTrue, reason: 'Pet, Play, Treat, Milestone, Games, Focus, Recap, Decorate, then Pause');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(settings.pauseReactions, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await follow(tester, const Duration(seconds: 1));
    await follow(tester);
    expect(state.surface, Surface.pet);
    expect(shell.shown.last, Surface.pet);
  });

  testWidgets("Milestone (the Mac's): a milestone you reached is recorded and celebrated (G2), for the session Mochi follows", (tester) async {
    await open(tester);
    expect(find.bySemanticsLabel('Mark a milestone you reached'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Mark a milestone you reached'));
    await tester.pump();
    final world = t.desktop.world;
    expect(world.world.progress.milestones, 1);
    expect(world.world.progress.unlockedIDs.map((id) => id.name), contains('firstMilestone'));
    expect(world.lastCelebration?.celebration.reason.name, 'firstMilestone', reason: 'graduation, the first time');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a click elsewhere closes it, and Mochi is back on the very spot it left; a click on Mochi opens it again', (tester) async {
    final state = await open(tester);
    final stroll = state.stroll;
    expect(shell.shows.last.surface, Surface.popover);
    final reading = taskbar.reading!;
    final panel = state.popoverGeometry!.panel;
    expect(panel.bottom, lessThanOrEqualTo(reading.workArea.bottom.toDouble()), reason: 'above the taskbar');
    expect(panel.left, greaterThanOrEqualTo(reading.workArea.left.toDouble()));
    expect(panel.right, lessThanOrEqualTo(reading.workArea.right.toDouble()), reason: 'inside the screen');
    expect(stroll.placement.name, 'away', reason: 'Mochi is in the popover, not on the taskbar');
    final left = window.frames.where((frame) => frame.width == 64).last;
    // Time passes with the popover open; then a click somewhere else.
    await tester.pump(const Duration(seconds: 20));
    shell.controller.add(ShellAction.dismissPopover);
    await follow(tester, const Duration(seconds: 1));
    await follow(tester);
    expect(state.surface, Surface.pet);
    expect(stroll.onTaskbar, isTrue);
    expect(window.frames.last, left, reason: 'the very spot it left');
    await tester.tap(find.byType(GestureDetector).first);
    await follow(tester);
    expect(state.surface, Surface.popover);
  });

  testWidgets('Open Mochi, Ask Mochi and Settings go on from the popover', (tester) async {
    final state = await open(tester);
    tester.view.physicalSize = SurfaceSizes.main;
    await tester.tap(find.text('Ask Mochi'));
    await tester.pump(const Duration(milliseconds: 300));
    expect((state.surface, state.page), (Surface.main, MainPage.home));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<AskBox>(find.byType(AskBox)).autofocus, isTrue, reason: 'the question box is ready');
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<AskBox>(), isNotNull, reason: 'with the focus');
    state.closeMain();
    await follow(tester);
    await tester.tap(find.byType(GestureDetector).first);
    await follow(tester);
    tester.view.physicalSize = SurfaceSizes.settings;
    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    expect((state.surface, state.page), (Surface.main, MainPage.settings));
  });

  testWidgets('the fun row’s Games opens the Games window (W14)', (tester) async {
    final state = await open(tester);
    tester.view.physicalSize = SurfaceSizes.games;
    final games = find.bySemanticsLabel(RegExp('^Games: Catch the Treats'));
    await tester.ensureVisible(games);
    await tester.tap(games);
    await tester.pump(const Duration(milliseconds: 300));
    expect((state.surface, state.page), (Surface.main, MainPage.games));
    expect(shell.mainSize, SurfaceSizes.games);
  });
}
