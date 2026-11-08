// Desktop icon play on the stage (docs/SPRINT_2.md X5): a visit on a desktop adventure (off by default, about one outing in
// two, the development switch), the icons it skips, once per outing, the visit ending at home and Mochi carrying on, every
// abort path putting the icon back, and the journal replayed at start. The put-back contract itself is in icon_play_test.dart.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/icon_play.dart';
import 'package:mochi_desktop/src/core/json_store.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/native_stage.dart' show StagePointerKind;
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect;
import 'package:mochi_desktop/src/platform/window_frames.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart' show PetHome;
import 'package:mochi_desktop/src/ui/stage/adventure.dart';
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';

import 'support/fake_icons.dart';
import 'support/fake_stage.dart';
import 'support/fakes.dart';

class _Home extends ChangeNotifier implements PetHome {
  final (int, int) at = (300, 1068);

  @override
  bool out = false;

  @override
  bool get canGoOut => !out;

  @override
  ({int x, int y, double scale, double facing, double unit})? departure() => (x: at.$1, y: at.$2, scale: 1, facing: 1.0, unit: 0.56);

  @override
  void goOut() {
    out = true;
    notifyListeners();
  }

  @override
  void comeBack({int? x}) {
    out = false;
    notifyListeners();
  }
}

/// Dice that always say [value] to nextInt (0: lucky now; 1: never).
class _Dice implements math.Random {
  int value = 0;

  @override
  double nextDouble() => 0.5;

  @override
  int nextInt(int max) => value;

  @override
  bool nextBool() => false;
}

void main() {
  const editorRect = PixelRect(900, 300, 1500, 800);

  late TestDesktop t;
  late FakeNativeStage stage;
  late _Home home;
  late FakeWindowFrames frames;
  late FakeIcons icons;
  late MemoryJsonStore store;
  late MischiefStage mischief;
  late List<String> log;
  late _Dice dice;
  var now = DateTime(2026, 11, 8, 15);

  setUp(() {
    now = DateTime(2026, 11, 8, 15);
    t = TestDesktop.make(clock: () => now, activity: const SystemActivity(idleSeconds: 1));
    t.desktop.rhythm.sample();
    stage = FakeNativeStage();
    home = _Home();
    log = [];
    dice = _Dice();
    store = MemoryJsonStore();
    frames = FakeWindowFrames([const WindowFrame(hwnd: 11, frame: editorRect)]);
    // Icons on the left of the main display, clear of the editor.
    icons = FakeIcons({'a': (100, 100), 'b': (250, 100), 'c': (100, 300), 'd': (400, 600)});
    mischief = MischiefStage(desktop: t.desktop, stage: stage, displays: FakeDisplays(), cursor: () => null);
  });

  tearDown(() async {
    mischief.dispose();
    await t.dispose();
  });

  DesktopAdventure adventure() => mischief.adventure!;

  void begin({bool extra = true, bool master = true, IconForce? force, bool nudges = false, JsonStore? journal}) {
    mischief = MischiefStage(
      desktop: t.desktop,
      stage: stage,
      displays: FakeDisplays([FakeDisplays.main1080, FakeDisplays.side1440]),
      cursor: () => null,
      home: home,
      frames: frames,
      desktopIcons: icons,
      iconStore: journal ?? store,
      iconLog: log.add,
      iconForce: force,
      iconRandom: dice,
    );
    t.desktop.mischief.start();
    mischief.start();
    t.desktop.settings.mischief = MischiefSettings(
      enabled: master,
      extras: {MischiefExtra.cursorBuddy: false, MischiefExtra.roamScreens: false, MischiefExtra.titleBars: false, MischiefExtra.windowNudges: nudges, MischiefExtra.desktopIcons: extra},
    );
  }

  Future<void> run(WidgetTester tester, double seconds, {bool Function()? until}) async {
    for (var i = 0; i < (seconds * 1000 / 33).ceil(); i++) {
      await tester.pump(const Duration(milliseconds: 33));
      if (until != null && until()) return;
    }
  }

  Future<void> done(WidgetTester tester) async {
    mischief.adventure?.stop();
    mischief.roamer?.stop();
    mischief.dispose();
    t.desktop.mischief.stop();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> drop(WidgetTester tester) async {
    expect(adventure().dropped(1200, 250), isTrue);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
  }

  bool visiting() => adventure().perfState()?.contains('visiting an icon') ?? false;
  const homes = {'a': (100, 100), 'b': (250, 100), 'c': (100, 300), 'd': (400, 600)};
  bool away() => icons.positions.entries.any((e) => homes[e.key] != e.value);

  /// Runs until Mochi is on a visit with an icon kicked (and the visit can still be cut).
  Future<void> kicked(WidgetTester tester) async {
    await drop(tester);
    await run(tester, 25, until: () => visiting() && away());
    expect(visiting(), isTrue, reason: 'a visit began');
    expect(away(), isTrue, reason: 'an icon was kicked');
    await run(tester, 0.1);
    expect(visiting(), isTrue, reason: 'and Mochi is sitting by it');
  }

  void homeAgain() {
    expect(icons.positions, homes, reason: 'every icon is exactly where it was');
  }

  group('the visit', () {
    testWidgets('off by default, even with Mischief on: nothing is read or moved', (tester) async {
      begin();
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      expect(t.desktop.settings.mischief.on(MischiefExtra.desktopIcons), isFalse);
      await drop(tester);
      await run(tester, 20);
      expect(icons.reads, 0);
      expect(icons.moves, isEmpty);
      expect(log, isEmpty);
      await done(tester);
    });

    testWidgets('the development switch: every outing visits, the icon is kicked and put back exactly, and Mochi carries on', (tester) async {
      begin(force: IconForce.visit);
      await drop(tester);
      await run(tester, 30, until: () => log.isNotEmpty);
      await run(tester, 3, until: () => !visiting());
      expect(log, ['icons: kicked, home ok']);
      homeAgain();
      expect(icons.moves.length, 2, reason: 'the kick and the way home');
      expect(icons.moves.first.$1, icons.moves.last.$1, reason: 'one icon');
      expect(store.json, isNull);
      expect(visiting(), isFalse);
      expect(adventure().active, isTrue, reason: 'it carries on exploring');
      expect(adventure().plan, isNotNull);
      await done(tester);
    });

    testWidgets('the nearest icon to Mochi is the one it visits, and it sits on it first (feet on the top of its picture)', (tester) async {
      begin(force: IconForce.visit);
      await drop(tester);
      var sat = false;
      await run(tester, 30, until: () {
        final feet = adventure().feet;
        if (visiting() && feet != null && icons.moves.isEmpty && feet == (437, 600)) sat = true;
        return log.isNotEmpty;
      });
      expect(sat, isTrue, reason: 'on the top of d’s picture (the cell 400 + 13 + 24 across, 600 down) before anything moved');
      expect(icons.moves.first.$1, 'd', reason: 'the nearest to where Mochi is on the editor’s top');
      await done(tester);
    });

    testWidgets('once per outing', (tester) async {
      begin(force: IconForce.visit);
      await drop(tester);
      await run(tester, 30, until: () => log.isNotEmpty);
      final reads = icons.reads;
      await run(tester, 20);
      expect(log.length, 1);
      expect(icons.moves.length, 2);
      expect(icons.reads, reads, reason: 'and no looking again either');
      await done(tester);
    });

    testWidgets('about one outing in two: the dice decide without the switch', (tester) async {
      dice.value = 1;
      begin();
      await drop(tester);
      await run(tester, 20);
      expect(icons.reads, 0, reason: 'unlucky: not even a look at the desktop');
      adventure().stop();
      await tester.pump(const Duration(milliseconds: 100));
      dice.value = 0;
      await drop(tester);
      await run(tester, 30, until: () => log.isNotEmpty);
      expect(log, ['icons: kicked, home ok']);
      await done(tester);
    });

    testWidgets('never from the taskbar stroll: with no adventure nothing reads the desktop', (tester) async {
      begin(force: IconForce.visit);
      await tester.pump(const Duration(seconds: 5));
      expect(icons.reads, 0);
      await done(tester);
    });

    testWidgets('covered icons are skipped: none free', (tester) async {
      frames.windows = [const WindowFrame(hwnd: 11, frame: editorRect), const WindowFrame(hwnd: 12, frame: PixelRect(0, 0, 700, 800))];
      begin(force: IconForce.visit);
      await drop(tester);
      await run(tester, 15, until: () => log.isNotEmpty);
      expect(log, ['icons: none free']);
      expect(icons.moves, isEmpty);
      await done(tester);
    });

    testWidgets('only the uncovered icons count: the covered nearest one is passed over', (tester) async {
      // d (400, 600) is the only one in the open.
      frames.windows = [const WindowFrame(hwnd: 11, frame: editorRect), const WindowFrame(hwnd: 12, frame: PixelRect(0, 0, 380, 450))];
      begin(force: IconForce.visit);
      await drop(tester);
      await run(tester, 30, until: () => log.isNotEmpty);
      expect(log, ['icons: kicked, home ok']);
      expect({for (final m in icons.moves) m.$1}, {'d'});
      homeAgain();
      await done(tester);
    });

    testWidgets('Auto arrange on: skipped; icons hidden: skipped', (tester) async {
      icons.autoArrange = true;
      begin(force: IconForce.visit);
      await drop(tester);
      await run(tester, 15, until: () => log.isNotEmpty);
      expect(log, ['icons: auto-arrange']);
      expect(icons.moves, isEmpty);
      adventure().stop();
      await tester.pump(const Duration(milliseconds: 100));
      log.clear();
      icons.autoArrange = false;
      icons.hidden = true;
      await drop(tester);
      await run(tester, 15, until: () => log.isNotEmpty);
      expect(log, ['icons: none free']);
      expect(icons.moves, isEmpty);
      await done(tester);
    });

    testWidgets('a desktop it can’t read: nothing happens', (tester) async {
      icons.failReads = true;
      begin(force: IconForce.visit);
      await drop(tester);
      await run(tester, 15);
      expect(icons.moves, isEmpty);
      expect(visiting(), isFalse);
      await done(tester);
    });

    testWidgets('an icon the user moves while Mochi is on it is left where they put it', (tester) async {
      begin(force: IconForce.visit);
      await drop(tester);
      await run(tester, 25, until: () => visiting() && away());
      final id = icons.moves.first.$1;
      icons.positions[id] = (1000, 900);
      await run(tester, 12, until: () => log.isNotEmpty);
      expect(log, ['icons: left (moved)']);
      expect(icons.positions[id], (1000, 900));
      expect(icons.movesOf(id).length, 1, reason: 'no put-back');
      expect(store.json, isNull);
      await done(tester);
    });
  });

  group('every abort path puts the icon back at once', () {
    testWidgets('a mouse button goes down', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      icons.mouse = true;
      await run(tester, 0.5);
      icons.mouse = false;
      homeAgain();
      expect(visiting(), isFalse);
      expect(adventure().active, isTrue, reason: 'Mochi carries on');
      expect(log.last, 'icons: kicked, home ok');
      await done(tester);
    });

    testWidgets('the desktop or a taskbar becomes the foreground', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      icons.desktopInUse = true;
      await run(tester, 0.5);
      icons.desktopInUse = false;
      homeAgain();
      expect(visiting(), isFalse);
      expect(log.last, 'icons: kicked, home ok');
      await done(tester);
    });

    testWidgets('the extra goes off', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      t.desktop.settings.mischief = t.desktop.settings.mischief.withExtra(MischiefExtra.desktopIcons, false);
      await run(tester, 0.5);
      homeAgain();
      expect(visiting(), isFalse);
      await done(tester);
    });

    testWidgets('Mischief goes off', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      t.desktop.settings.mischief = t.desktop.settings.mischief.copyWith(enabled: false);
      await run(tester, 0.5);
      homeAgain();
      expect(visiting(), isFalse);
      await done(tester);
    });

    testWidgets('the gate closes (a rule: reactions paused)', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      t.desktop.settings.pauseReactions = true;
      await tester.pump(const Duration(milliseconds: 100));
      await run(tester, 0.5);
      homeAgain();
      expect(visiting(), isFalse);
      await done(tester);
    });

    testWidgets('Mochi is sent home', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      expect(adventure().comeHome(), isTrue);
      await run(tester, 0.3);
      homeAgain();
      expect(visiting(), isFalse);
      expect(log.last, 'icons: kicked, home ok');
      await done(tester);
    });

    testWidgets('the adventure ends', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      adventure().stop();
      await run(tester, 0.3);
      homeAgain();
      expect(adventure().active, isFalse);
      expect(log.last, 'icons: kicked, home ok');
      await done(tester);
    });

    testWidgets('the app quits (the exit hook), and so does Windows ending the session', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      t.desktop.runExitHooks();
      await run(tester, 0.3);
      homeAgain();
      expect(store.json, isNull);
      await done(tester);
    });

    testWidgets('a click on Mochi (a mouse button down on it) puts it back', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      stage.point(adventure().pet.actor, StagePointerKind.down, screenX: adventure().feet!.$1, screenY: adventure().feet!.$2 - 20);
      await run(tester, 0.3);
      homeAgain();
      expect(visiting(), isFalse);
      await done(tester);
    });
  });

  group('the journal', () {
    testWidgets('it is written while an icon is away and gone once it is home', (tester) async {
      begin(force: IconForce.visit);
      await kicked(tester);
      final record = store.json as Map;
      expect(record['id'], icons.moves.first.$1);
      expect(record['placed'], isA<List<Object?>>());
      expect(record['home'], isA<List<Object?>>());
      await run(tester, 12, until: () => log.isNotEmpty);
      expect(store.json, isNull);
      await done(tester);
    });

    testWidgets('at start an icon left away by a crash goes home, and the file goes', (tester) async {
      icons.positions['c'] = (175, 300);
      store.write({'id': 'c', 'home': [100, 300], 'placed': [175, 300]});
      begin();
      await tester.pump(const Duration(milliseconds: 50));
      expect(icons.positions['c'], (100, 300));
      expect(store.json, isNull);
      await done(tester);
    });

    testWidgets('at start, an icon moved since (or gone) is left; the file goes either way', (tester) async {
      icons.positions['c'] = (555, 555);
      store.write({'id': 'c', 'home': [100, 300], 'placed': [175, 300]});
      begin();
      await tester.pump(const Duration(milliseconds: 50));
      expect(icons.positions['c'], (555, 555));
      expect(store.json, isNull);
      store.write({'id': 'zzz', 'home': [1, 1], 'placed': [2, 2]});
      mischief.dispose();
      begin();
      await tester.pump(const Duration(milliseconds: 50));
      expect(icons.moves, isEmpty);
      expect(store.json, isNull);
      await done(tester);
    });
  });
}
