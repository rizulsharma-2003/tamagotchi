// The mini-games on Windows (docs/SPRINT_2.md W14): Catch the Treats and rock-paper-scissors with Mochi and Patch,
// as the Mac's GamesController runs them (mochi_world's games, checked against the Mac's fixture): the moments in
// Mochi's world, the records under the Mac's `games` key, the keys and the mouse, pausing when the window loses the
// focus or closes, a picture that's only drawn every frame while a game is played, the popover's and the menus' way
// in, and Settings › Fun › Games. Light and dark, 1× and 2× text, and the screen reader.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart' show CompanionVisibility;
import 'package:mochi_desktop/src/core/games.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart' show SystemActivity;
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

void main() {
  final now = DateTime(2026, 11, 8, 15);

  group('Catch the Treats', () {
    late TestDesktop t;
    late double clock;

    setUp(() {
      clock = 100;
      t = TestDesktop.make(clock: () => now, uptime: () => clock, settings: {'soundEnabled': true});
    });
    tearDown(() => t.dispose());

    /// Plays [seconds] of the game at 60 frames a second.
    void play(double seconds) {
      for (var i = 0; i < seconds * 60; i++) {
        clock += 1 / 60;
        t.desktop.games.frame(clock);
      }
    }

    test('a catch scores and pops; three treats on the floor end the game, recorded under the Mac’s key', () {
      final games = t.desktop.games;
      expect(games.catchPhase, CatchPhase.ready);
      games.startCatch();
      expect(games.catchPhase, CatchPhase.playing);
      final game = games.session.game..autoSpawn = false;
      play(0.1);
      game.drop(w.TreatKind.cookie, game.petX, y: 0.3);
      final sounds = t.sound.played.length;
      play(1.5);
      expect(game.score, 1);
      expect(games.score.value, 1, reason: 'the screen reader hears the score');
      expect(t.sound.played.length, sounds + 1, reason: 'a pop, with sound on');
      for (final x in [0.05, 0.95, 0.9]) {
        game.drop(w.TreatKind.cookie, x, y: 0.6);
      }
      play(4);
      expect(games.catchPhase, CatchPhase.over);
      expect(games.lastScore, 1);
      expect(games.lastCaught, 1);
      expect(games.newRecord, isTrue);
      expect(t.desktop.world.toastNow.value?.title, 'New high score: 1!');
      expect(t.desktop.world.world.pet.current.animation, w.PetAnimation.excitedJump);
      final saved = t.document.json!['games']! as Map;
      expect(saved['catchHighScore'], 1);
      expect(saved['catchGamesPlayed'], 1);
      expect(saved['catchBestCombo'], 1);
      expect(t.desktop.settings.games.catchSummary, 'Best 1 · best combo 1 · 1 played');
      // A game that's over is never recorded twice.
      play(1);
      expect(t.desktop.settings.games.catchGamesPlayed, 1);
    });

    test('pausing holds the game still and resuming carries on without a jump in time', () {
      final games = t.desktop.games..startCatch();
      final game = games.session.game..autoSpawn = false;
      play(0.5);
      final before = game.time;
      games.pauseCatch();
      expect(games.catchPhase, CatchPhase.paused);
      play(5);
      expect(game.time, before, reason: 'nothing moves while paused');
      games.resumeCatch();
      play(1 / 60);
      expect(game.time, before, reason: 'the first frame back only sets the clock');
      play(0.5);
      expect(game.time, closeTo(before + 0.5, 0.02));
      games.toggleCatch();
      expect(games.catchPhase, CatchPhase.paused, reason: 'Space pauses');
      games.toggleCatch();
      expect(games.catchPhase, CatchPhase.playing, reason: 'and resumes');
      games.leave();
      expect(games.catchPhase, CatchPhase.paused, reason: 'the window lost the focus or closed');
    });

    test('switching to the other game pauses the treats, as on the Mac', () {
      final games = t.desktop.games..startCatch();
      games.tab = GameTab.rps;
      expect(games.catchPhase, CatchPhase.paused);
    });
  });

  group('Rock, paper, scissors', () {
    late TestDesktop t;

    setUp(() => t = TestDesktop.make(clock: () => now, settings: {'soundEnabled': true}));
    tearDown(() => t.dispose());

    testWidgets('a pick plays a round: the picks are fixed first, scored at the shake, the next after 3.6 s', (tester) async {
      final games = t.desktop.games;
      expect(games.match.withCompanion, isTrue, reason: 'Patch plays unless he never shows');
      games.pick(w.RPSChoice.rock);
      expect(games.busy, isTrue);
      final round = games.round!;
      expect(round.player, w.RPSChoice.rock);
      expect(round.companion, isNotNull);
      games.pick(w.RPSChoice.paper);
      expect(games.round, same(round), reason: 'no new pick while a round plays');
      await tester.pump(const Duration(milliseconds: 1400));
      expect(games.revealed, isFalse);
      await tester.pump(const Duration(milliseconds: 150));
      expect(games.revealed, isTrue);
      final records = t.desktop.settings.games;
      expect(records.rpsWins + records.rpsLosses + records.rpsDraws, 2, reason: 'one duel with each of them');
      expect((t.document.json!['games']! as Map)['rpsWins'], records.rpsWins, reason: 'the Mac’s key');
      expect(games.busy, isTrue);
      await tester.pump(const Duration(milliseconds: 2200));
      expect(games.busy, isFalse);
    });

    testWidgets('three wins in a row is a new best streak: a jump, a note and a fanfare', (tester) async {
      // The characters' picks come from the match's seed, decided before yours: a second match on the same seed shows
      // them, so each round can be won.
      final games = DesktopGames(settings: t.desktop.settings, world: t.desktop.world, seed: () => 42);
      addTearDown(games.dispose);
      final shadow = w.RPSMatch(42, withCompanion: true);
      for (var round = 0; round < 3; round++) {
        final picks = shadow.nextPicks();
        final winning = w.RPSChoice.values.firstWhere(
          (choice) => w.RPSRound(player: choice, pet: picks.pet, companion: picks.companion).isWin,
        );
        games.pick(winning);
        await tester.pump(const Duration(milliseconds: 1600));
        expect(games.match.streak, round + 1);
        await tester.pump(const Duration(milliseconds: 2100));
      }
      expect(t.desktop.settings.games.rpsBestStreak, 3);
      expect(t.desktop.world.toastNow.value?.title, 'New best streak: 3!');
      expect(t.desktop.world.world.pet.current.animation, w.PetAnimation.excitedJump);
    });

    test('with Patch set never to show, it’s you and Mochi (a new sitting once he’s gone)', () {
      final games = t.desktop.games;
      t.desktop.settings.companionVisibility = CompanionVisibility.never;
      games.show(GameTab.rps);
      expect(games.match.withCompanion, isFalse);
      expect(games.tab, GameTab.rps);
    });
  });

  group('The Games window', () {
    late TestDesktop t;
    late FakeShell shell;

    setUp(() {
      t = TestDesktop.make(clock: () => now, settings: {'soundEnabled': true});
      shell = FakeShell();
    });
    tearDown(() => t.dispose());

    Future<DesktopAppState> open(WidgetTester tester, {double scale = 1, Surface surface = Surface.main, MainPage page = MainPage.games}) async {
      tester.view.physicalSize = SurfaceSizes.games;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        DesktopApp(desktop: t.desktop, shell: shell, initialSurface: surface, initialPage: page, library: Future<PoseLibrary?>.value()),
      );
      await tester.pump(const Duration(milliseconds: 300));
      return tester.state<DesktopAppState>(find.byType(DesktopApp));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    }

    testWidgets('both games in light and dark, at 1× and 2× text, with nothing cut off', (tester) async {
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        for (final scale in [1.0, 2.0]) {
          t.desktop.settings.themeMode = theme;
          await open(tester, scale: scale);
          expect(find.text('Catch the Treats'), findsWidgets);
          expect(find.text('Play'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '${theme.name} ${scale}x');
          await tester.tap(find.text('Rock, Paper, Scissors'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Pick one: you play Mochi and Patch at once.'), findsOneWidget);
          expect(find.text('Scissors'), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '${theme.name} ${scale}x');
          t.desktop.games.tab = GameTab.catchTreats;
          await close(tester);
        }
      }
    });

    testWidgets('the keys: Space plays and pauses, ← → and A D run, Escape pauses (and closes when no game is going)', (tester) async {
      final state = await open(tester);
      final games = t.desktop.games;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(games.catchPhase, CatchPhase.playing);
      games.session.game.autoSpawn = false;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final start = games.session.game.petX;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      expect(games.session.game.petX, greaterThan(start + 0.1), reason: 'Mochi ran right');
      final right = games.session.game.petX;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      expect(games.session.game.petX, lessThan(right), reason: 'A runs left');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(games.catchPhase, CatchPhase.paused);
      expect(state.surface, Surface.main, reason: 'Escape paused the game; the window stays');
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Mochi is waiting patiently.'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(games.catchPhase, CatchPhase.playing);
      await close(tester);
    });

    testWidgets('dragging with the mouse moves Mochi to the pointer', (tester) async {
      await open(tester);
      final games = t.desktop.games;
      await tester.tap(find.text('Play'));
      await tester.pump();
      expect(games.catchPhase, CatchPhase.playing);
      games.session.game.autoSpawn = false;
      final field = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter.runtimeType.toString() == 'CatchFieldPainter');
      final box = tester.getRect(field);
      final gesture = await tester.startGesture(box.centerLeft + Offset(box.width * 0.15, 0));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(games.session.game.petX, lessThan(0.3), reason: 'Mochi followed the pointer to the left');
      await gesture.moveBy(Offset(box.width * 0.65, 0));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(games.session.game.petX, greaterThan(0.7));
      await gesture.up();
      expect(games.session.dragX, isNull);
      await close(tester);
    });

    testWidgets('the field is drawn every frame only while a game is played; nothing while the screen can’t be seen', (tester) async {
      await open(tester);
      final games = t.desktop.games;
      dynamic field() => tester.state(find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_CatchView'));
      expect((field() as dynamic).fps, 12, reason: 'clouds drift between games');
      games.startCatch();
      await tester.pump();
      expect((field() as dynamic).fps, 60);
      games.pauseCatch();
      await tester.pump();
      expect((field() as dynamic).fps, 12);
      t.usage.activity = const SystemActivity(idleSeconds: 0, displaysAsleep: true);
      t.desktop.rhythm.sample();
      await tester.pump();
      expect((field() as dynamic).fps, 0, reason: 'the display is off');
      games.startCatch();
      await tester.pump();
      expect((field() as dynamic).fps, 0, reason: 'not even for a game');
      t.usage.activity = const SystemActivity(idleSeconds: 0);
      t.desktop.rhythm.sample();
      await tester.pump();
      expect((field() as dynamic).fps, 60);
      await close(tester);
    });

    testWidgets('losing the focus pauses the treats; leaving the page does too', (tester) async {
      final state = await open(tester);
      final games = t.desktop.games..startCatch();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(games.catchPhase, CatchPhase.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      games.resumeCatch();
      await tester.pump();
      state.open(MainPage.home);
      await tester.pump(const Duration(milliseconds: 300));
      expect(games.catchPhase, CatchPhase.paused);
      await close(tester);
    });

    testWidgets('rock-paper-scissors from the keys (R, P, S or 1, 2, 3), with the result said aloud', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      final games = t.desktop.games;
      await tester.tap(find.text('Rock, Paper, Scissors'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      expect(games.round?.player, w.RPSChoice.paper);
      expect(find.text('Rock… paper… scissors…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1600));
      final result = games.round!.result(petName: 'Mochi', companionName: 'Patch');
      expect(find.text(result.headline), findsOneWidget);
      expect(find.bySemanticsLabel('${result.headline} ${result.detail}'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2100));
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      expect(games.round?.player, w.RPSChoice.scissors);
      await tester.pump(const Duration(seconds: 4));
      expect(find.bySemanticsLabel(RegExp(r'^vs Mochi: \d+ won, \d+ lost, \d+ drawn this sitting$')), findsOneWidget);
      expect(find.bySemanticsLabel('Rock, R or 1'), findsOneWidget);
      handle.dispose();
      await close(tester);
    });

    testWidgets('the popover’s Games button and the tray’s Games… open it', (tester) async {
      final state = await open(tester, surface: Surface.pet, page: MainPage.home);
      shell.controller.add(ShellAction.games);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.surface, Surface.main);
      expect(state.page, MainPage.games);
      expect(find.byType(SegmentedButton<GameTab>), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.surface, Surface.pet, reason: 'opened from the tray: Escape goes back to the desktop');
      expect(NativeShell.trayItems(style: t.desktop.settings.petStyle).map((item) => item.label), contains('Games…'));
      await close(tester);
    });

    testWidgets('Settings › Fun › Games: the records, Play… and Reset Records…', (tester) async {
      t.desktop.settings.games = w.GameRecords(catchHighScore: 42, catchGamesPlayed: 3, catchBestCombo: 9, rpsWins: 4, rpsLosses: 2, rpsDraws: 1);
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: shell,
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.fun,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('Best 42 · best combo 9 · 3 played'));
      expect(find.text('4 won · 2 lost · 1 drawn'), findsOneWidget);
      expect(find.text('Games'), findsWidgets);
      await tester.tap(find.text('Reset Records…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset Records').last);
      await tester.pumpAndSettle();
      expect(t.desktop.settings.games.isEmpty, isTrue);
      expect(find.text('Not played yet'), findsNWidgets(2));
      await tester.tap(find.text('Play…'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.state<DesktopAppState>(find.byType(DesktopApp)).page, MainPage.games);
      await close(tester);
    });
  });
}
