// The title-bar walker (docs/SPRINT_2.md X1): while Mochi stands on a window's top on an adventure, it holds on and rides
// along when you drag that window (feet glued to the same spot of its top edge, in a holding-on pose), rides a resize that
// keeps its spot, and falls to the surface below when the window is minimised, closed, snapped or maximised, dragged
// too high or onto another display. It only ever reads that one window's frame, about eight times a second while the window
// is still and every frame while it moves, and not at all with the switch off or while the screen is unseen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect;
import 'package:mochi_desktop/src/platform/window_frames.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart' show PetHome;
import 'package:mochi_desktop/src/ui/stage/adventure.dart';
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fake_stage.dart';
import 'support/fakes.dart';

class _Home extends ChangeNotifier implements PetHome {
  final (int, int) at = (300, 1068);
  final List<int?> returns = [];

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
    returns.add(x);
    notifyListeners();
  }
}

void main() {
  const main = FakeDisplays.main1080, side = FakeDisplays.side1440;

  // The only window: on the main display (1920×1080, taskbar 48 tall), its top at y 300 (780 up from the bottom).
  const editor = WindowFrame(hwnd: 11, frame: PixelRect(400, 300, 1100, 800));

  late TestDesktop t;
  late FakeNativeStage stage;
  late _Home home;
  late FakeWindowFrames frames;
  late MischiefStage mischief;

  setUp(() {
    t = TestDesktop.make(clock: () => DateTime(2026, 11, 8, 15), activity: const SystemActivity(idleSeconds: 1));
    t.desktop.rhythm.sample();
    stage = FakeNativeStage();
    home = _Home();
    frames = FakeWindowFrames([editor]);
    mischief = MischiefStage(desktop: t.desktop, stage: stage, displays: FakeDisplays(), cursor: () => null);
  });

  tearDown(() async {
    mischief.dispose();
    await t.dispose();
  });

  DesktopAdventure adventure() => mischief.adventure!;

  /// Mischief (the buddy and the roamer off, so they don't take Mochi) with the walker on, off, or Mischief itself off.
  void begin({bool master = true, bool walker = true}) {
    mischief = MischiefStage(
      desktop: t.desktop,
      stage: stage,
      displays: FakeDisplays([main, side]),
      cursor: () => null,
      home: home,
      frames: frames,
    );
    t.desktop.mischief.start();
    mischief.start();
    t.desktop.settings.mischief = MischiefSettings(
      enabled: master,
      extras: {MischiefExtra.cursorBuddy: false, MischiefExtra.roamScreens: false, MischiefExtra.titleBars: walker},
    );
  }

  Future<void> run(WidgetTester tester, double seconds) async {
    final steps = (seconds * 1000 / 33).ceil();
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  Future<void> done(WidgetTester tester) async {
    mischief.adventure?.stop();
    mischief.buddy?.stop();
    mischief.roamer?.stop();
    t.desktop.mischief.stop();
    await tester.pump();
  }

  /// Mochi dropped over the editor: it falls onto its top and stands there.
  Future<void> landed(WidgetTester tester) async {
    expect(adventure().dropped(700, 250), isTrue);
    await run(tester, 0.6);
    expect(adventure().feet!.$2, 300, reason: 'on the editor’s top');
  }

  /// Moves the editor to [to] over [steps] frames, as a drag does.
  Future<void> drag(WidgetTester tester, PixelRect to, {int steps = 4}) async {
    final from = frames.windows.first.frame;
    for (var i = 1; i <= steps; i++) {
      final k = i / steps;
      int at(int a, int b) => (a + (b - a) * k).round();
      frames.windows = [WindowFrame(hwnd: 11, frame: PixelRect(at(from.left, to.left), at(from.top, to.top), at(from.right, to.right), at(from.bottom, to.bottom)))];
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  /// A second on from a fall: Mochi is on the floor of the display (the taskbar's top), or at least on its way down.
  void expectFell() {
    expect(adventure().riding, isFalse);
    expect(adventure().plan, isNotNull);
    expect(adventure().plan!.segments.first.move, w.AdventureMove.fall);
  }

  testWidgets('a dragged window takes Mochi with it: feet glued to the same spot of its top edge, in a holding-on pose', (tester) async {
    begin();
    await landed(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await run(tester, 0.2);
    // The window is picked up and moved (right and down) a step at a time (Mochi may walk a step before it notices).
    int? offset;
    for (var i = 1; i <= 8; i++) {
      frames.windows = [WindowFrame(hwnd: 11, frame: PixelRect.ltwh(400 + i * 40, 300 + i * 20, 700, 500))];
      await tester.pump(const Duration(milliseconds: 33));
      if (i < 5 && !adventure().riding) continue;
      expect(adventure().riding, isTrue, reason: 'step $i');
      expect(adventure().perfState(), 'adventure (riding a window)');
      final feet = adventure().feet!;
      offset ??= feet.$1 - frames.windows.first.frame.left;
      expect(feet.$1 - frames.windows.first.frame.left, offset, reason: 'glued to the same spot');
      expect(feet.$2, frames.windows.first.frame.top, reason: 'on the top edge');
    }
    expect(adventure().every, DesktopAdventure.moveEvery);
    // The holding-on pose.
    final pose = w.PetPose();
    DesktopAdventure.holdOn(pose);
    expect((pose.eyes, pose.leftArm, pose.earPerk < 0), (w.PetEyes.wide, 0.45, true));
    // It stays where the window stops, and after a moment carries on from there, on its new top.
    await run(tester, 0.2);
    expect(adventure().riding, isTrue);
    await run(tester, 0.6);
    expect(adventure().riding, isFalse);
    expect(adventure().terrain!.ledges.single.y, 1080 - (300 + 8 * 20), reason: 'the window as it is now');
    expect(adventure().plan!.sample(t.desktop.world.now()).point.y, closeTo(1080 - 460, 1));
    await run(tester, 2);
    // It walks on the window's new top (or has left it for the floor, but never drifted off in the air).
    final point = adventure().plan!.sample(t.desktop.world.now()).point;
    expect(adventure().terrain!.supports(point, tolerance: 3) || adventure().plan!.sample(t.desktop.world.now()).isAirborne, isTrue);
    await done(tester);
  });

  testWidgets('it falls when the window is minimised, closed, snapped or maximised', (tester) async {
    final cases = <String, void Function()>{
      'minimised': () => frames.minimised.add(11),
      'closed': () => frames.windows = [],
      'snapped': () => frames.windows = [const WindowFrame(hwnd: 11, frame: PixelRect(960, 0, 1920, 1032))],
      'maximised': () => frames.windows = [const WindowFrame(hwnd: 11, frame: PixelRect(0, 0, 1920, 1032), zoomed: true)],
    };
    for (final MapEntry(key: name, value: change) in cases.entries) {
      frames.minimised.clear();
      frames.windows = [editor];
      begin();
      await landed(tester);
      change();
      await run(tester, 0.2);
      expectFell();
      expect(adventure().plan!.segments.first.from.y, closeTo(780, 1), reason: '$name: it falls from where it stood');
      await run(tester, 1.5);
      expect(adventure().terrain!.supports(adventure().plan!.sample(t.desktop.world.now()).point, tolerance: 3) || adventure().plan!.sample(t.desktop.world.now()).isAirborne, isTrue, reason: name);
      expect(adventure().plan!.sample(t.desktop.world.now()).point.y, lessThan(780), reason: '$name: down from the window’s top');
      await done(tester);
    }
  });

  testWidgets('a resize that keeps its spot on the top edge is ridden; one that takes the edge from under it is not', (tester) async {
    begin();
    await landed(tester);
    // Wider (the right edge dragged): nothing under it changes.
    await drag(tester, const PixelRect(400, 300, 1160, 800), steps: 2);
    await run(tester, 0.15);
    expect(adventure().riding, isTrue);
    expect(adventure().feet!.$2, 300);
    final x = adventure().feet!.$1;
    // The top edge dragged down a little: it stays on the edge.
    await drag(tester, const PixelRect(400, 340, 1160, 800), steps: 2);
    expect(adventure().riding, isTrue);
    expect(adventure().feet!.$2, 340);
    expect((adventure().feet!.$1 - x).abs(), lessThanOrEqualTo(1), reason: 'where it stood across');
    // The left edge dragged in past its spot, a little at a time: the edge no longer holds it.
    await drag(tester, PixelRect(x + 60, 340, 1160, 800), steps: 12);
    await run(tester, 0.2);
    expectFell();
    await done(tester);
  });

  testWidgets('dragged so high that Mochi’s head would leave the display, or onto another display: it falls off', (tester) async {
    begin();
    await landed(tester);
    await drag(tester, const PixelRect(400, 120, 1100, 620), steps: 4);
    expect(adventure().riding, isTrue, reason: 'still on the display');
    await drag(tester, const PixelRect(400, 20, 1100, 520), steps: 3);
    await run(tester, 0.2);
    expectFell();
    await done(tester);

    frames.windows = [editor];
    begin();
    await landed(tester);
    await drag(tester, const PixelRect(1900, 300, 2600, 800), steps: 2);
    await run(tester, 0.2);
    expectFell();
    await done(tester);
  });

  testWidgets('with the switch off (or Mischief off) no window is read but in the regular survey; with it on the stand is read eight a second, a drag every frame', (tester) async {
    for (final (master, walker) in [(false, true), (true, false)]) {
      frames.windows = [editor];
      frames.reads = 0;
      begin(master: master, walker: walker);
      await landed(tester);
      await run(tester, 2);
      expect(frames.reads, 0, reason: 'master $master, walker $walker: no reads of one window at all');
      // Dragging it does nothing to Mochi but what the survey does on the Mac: it falls when its ledge is gone.
      frames.windows = [WindowFrame(hwnd: 11, frame: PixelRect.ltwh(900, 500, 700, 500))];
      await run(tester, 1);
      expect(adventure().riding, isFalse);
      expect(frames.reads, 0);
      await done(tester);
    }
    frames.windows = [editor];
    frames.reads = 0;
    begin();
    await landed(tester);
    await run(tester, 0.3);
    final still = frames.reads;
    await run(tester, 1);
    expect(frames.reads - still, inInclusiveRange(6, 11), reason: 'about eight a second while the window is still');
    final moving = frames.reads;
    for (var i = 1; i <= 30; i++) {
      frames.windows = [WindowFrame(hwnd: 11, frame: PixelRect.ltwh(400 + i * 4, 300, 700, 500))];
      await tester.pump(const Duration(milliseconds: 33));
    }
    expect(frames.reads - moving, inInclusiveRange(28, 36), reason: 'every frame while it moves');
    await done(tester);
  });

  testWidgets('nothing is read while the screen is unseen (Mochi is home by then)', (tester) async {
    begin();
    await landed(tester);
    await run(tester, 0.5);
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
    expect(adventure().active, isFalse);
    final reads = frames.reads, lists = frames.lists;
    await run(tester, 3);
    expect((frames.reads, frames.lists), (reads, lists));
    await done(tester);
  });

  testWidgets('Mochi’s window opening while it rides sends it home at once; Come home while it rides hurries it', (tester) async {
    begin();
    await landed(tester);
    frames.windows = [WindowFrame(hwnd: 11, frame: PixelRect.ltwh(500, 300, 700, 500))];
    await run(tester, 0.1);
    expect(adventure().riding, isTrue);
    expect(adventure().comeHome(), isTrue);
    expect(adventure().riding, isFalse);
    expect(adventure().perfState(), 'adventure (heading home)');
    await run(tester, 4);
    expect(adventure().active, isFalse);
    await done(tester);
  });

  test('the Settings switch is one of Mischief’s extras, on with the master switch and moving', () {
    expect(MischiefExtra.available, contains(MischiefExtra.titleBars));
    expect(MischiefExtra.titleBars.title, 'Title-bar walker');
    expect(MischiefExtra.titleBars.moves, isTrue);
    expect(MischiefSettings.fromJson(const MischiefSettings(enabled: true).toJson()).on(MischiefExtra.titleBars), isTrue);
    expect(MischiefSettings.fromJson({'enabled': true, 'titleBars': false}).on(MischiefExtra.titleBars), isFalse);
  });
}
