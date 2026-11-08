// The cursor buddy (docs/SPRINT_2.md X4): Mochi hops off the taskbar and keeps the pointer company (chases it, pounces
// beside it, sits by it, naps by it), reading the pointer only, letting clicks through while it runs, slowing down when
// the pointer is still and stopping while nobody can see the screen; it goes home when Mischief says no (at once for a
// full-screen app or Mochi's window, at a run otherwise) to where it left from. And the taskbar's side of it: Mochi
// away, Patch staying at his desk.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show QuietHours;
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/native_stage.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart' show PetHome;
import 'package:mochi_desktop/src/ui/stage/cursor_buddy.dart';
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';

import 'support/fake_stage.dart';
import 'support/fakes.dart';

/// The taskbar, as the buddy sees it: Mochi stands at [at], goes out and comes back.
class FakeHome extends ChangeNotifier implements PetHome {
  (int, int) at = (300, 1068);
  double scale = 1;
  bool showing = true;
  final List<int?> returns = [];
  int outings = 0;

  @override
  bool out = false;

  @override
  bool get canGoOut => showing && !out;

  @override
  ({int x, int y, double scale, double facing, double unit})? departure() =>
      showing ? (x: at.$1, y: at.$2, scale: scale, facing: 1.0, unit: 0.56) : null;

  @override
  void goOut() {
    out = true;
    outings++;
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
  late TestDesktop t;
  late FakeNativeStage stage;
  late FakeHome home;
  late MischiefStage mischief;
  late FakeDisplays displays;
  (int, int)? pointer;
  var shown = true;
  var fullScreen = false;
  var now = DateTime(2026, 11, 8, 15);
  var reads = 0;

  setUp(() {
    pointer = (900, 500);
    shown = true;
    fullScreen = false;
    reads = 0;
    now = DateTime(2026, 11, 8, 15);
    t = TestDesktop.make(clock: () => now, fullScreen: () => fullScreen, activity: const SystemActivity(idleSeconds: 1));
    t.desktop.rhythm.sample();
    stage = FakeNativeStage();
    home = FakeHome();
    displays = FakeDisplays([FakeDisplays.main1080, FakeDisplays.side1440]);
  });

  tearDown(() async {
    mischief.dispose();
    await t.dispose();
  });

  CursorBuddy buddy() => mischief.buddy!;

  /// Mischief and the buddy, started inside the test (their timers run on the test's clock).
  void begin({bool on = true}) {
    mischief = MischiefStage(
      desktop: t.desktop,
      stage: stage,
      displays: displays,
      cursor: () {
        reads++;
        return pointer;
      },
      home: home,
      shown: () => shown,
    );
    t.desktop.mischief.start();
    mischief.start();
    if (on) t.desktop.settings.mischief = const MischiefSettings(enabled: true);
  }

  Future<void> run(WidgetTester tester, double seconds, {Duration step = const Duration(milliseconds: 33)}) async {
    final steps = (seconds * 1000 / step.inMilliseconds).ceil();
    for (var i = 0; i < steps; i++) {
      await tester.pump(step);
    }
  }

  Future<void> done(WidgetTester tester) async {
    mischief.buddy?.stop();
    mischief.roamer?.stop();
    t.desktop.mischief.stop();
    await tester.pump();
  }

  double distance((int, int) a, (int, int) b) => ((a.$1 - b.$1) * (a.$1 - b.$1) + (a.$2 - b.$2) * (a.$2 - b.$2)).toDouble();

  testWidgets('it waits for Mischief and its switch; then it hops out from where Mochi stood on the taskbar', (tester) async {
    begin(on: false);
    expect(buddy().active, isFalse);
    expect(home.out, isFalse);
    t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.cursorBuddy: false});
    expect(buddy().active, isFalse, reason: 'its own switch is off');
    t.desktop.settings.mischief = const MischiefSettings(enabled: true);
    expect(buddy().active, isTrue);
    expect(home.out, isTrue);
    expect(buddy().feet, home.at, reason: 'from where it stood');
    expect(buddy().mode, BuddyMode.chase);
    await done(tester);
  });

  testWidgets('it chases the pointer, lets clicks through while it runs, and ends up beside it facing it', (tester) async {
    begin();
    await run(tester, 0.3);
    expect(buddy().mode, BuddyMode.chase);
    // Drawn as soon as its pictures are ready, click-through while it runs.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await run(tester, 0.1);
    final shot = stage.showing[mischief.pet!.actor]!;
    expect(shot.clickThrough, isTrue);
    expect(shot.topmost, isTrue);
    await run(tester, 2.5);
    final (x, y) = buddy().feet;
    expect((x - (900 - CursorBuddy.besideX)).abs() <= 4 || (x - (900 + CursorBuddy.besideX)).abs() <= 4, isTrue, reason: 'beside the pointer: $x');
    expect((y - (500 + CursorBuddy.belowY)).abs(), lessThanOrEqualTo(4));
    expect(x, lessThan(900), reason: 'on the side it came from (the taskbar was to the left)');
    await done(tester);
  });

  testWidgets('the pointer stops: a pounce, then it sits (and takes clicks: a click pets it); idle, it naps; the reads slow down', (
    tester,
  ) async {
    begin();
    await run(tester, 3);
    expect(buddy().mode, isIn([BuddyMode.pounce, BuddyMode.sit]));
    await run(tester, 1.5);
    expect(buddy().mode, BuddyMode.sit);
    expect(buddy().every, CursorBuddy.sitEvery, reason: 'eight reads a second while it sits');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await run(tester, 0.3, step: CursorBuddy.sitEvery);
    final actor = mischief.pet!.actor;
    expect(stage.showing[actor]!.clickThrough, isFalse, reason: 'sitting, it can be petted');
    expect(stage.showing[actor]!.hand, isTrue);
    final points = t.desktop.world.world.progress.affectionPoints;
    stage
      ..point(actor, StagePointerKind.down, x: 20, y: 20)
      ..point(actor, StagePointerKind.up, x: 21, y: 20);
    expect(t.desktop.world.world.progress.affectionPoints, greaterThan(points), reason: 'a pet');
    // A long while without the pointer moving: a nap, and fewer reads still.
    await run(tester, CursorBuddy.napAfter + 1, step: CursorBuddy.sitEvery);
    expect(buddy().mode, BuddyMode.nap);
    expect(buddy().every, CursorBuddy.napEvery);
    final before = reads;
    await run(tester, 1, step: const Duration(milliseconds: 100));
    expect(reads - before, lessThanOrEqualTo(7), reason: 'about six reads a second asleep');
    // The pointer moves: awake and after it.
    pointer = (1400, 300);
    await run(tester, 0.2, step: CursorBuddy.napEvery);
    expect(buddy().mode, BuddyMode.chase);
    expect(buddy().every, CursorBuddy.runEvery);
    await done(tester);
  });

  testWidgets('nothing at all while nobody can see the screen; then it carries on from where it was', (tester) async {
    begin();
    await run(tester, 0.5);
    final where = buddy().feet;
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
    expect(buddy().paused, isTrue);
    expect(buddy().every, isNull, reason: 'no timer');
    expect(stage.showing, isEmpty, reason: 'hidden');
    expect(home.out, isTrue, reason: 'still out (not back on the taskbar)');
    final before = reads;
    await run(tester, 5);
    expect(reads, before, reason: 'the pointer isn’t read');
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 0));
    expect(buddy().paused, isFalse);
    expect(distance(buddy().feet, where), lessThan(40 * 40.0));
    expect(buddy().every, isNotNull);
    await done(tester);
  });

  testWidgets('a full-screen app, or Mochi’s window opening: home at once, to where it left from', (tester) async {
    begin();
    await run(tester, 1);
    fullScreen = true;
    t.desktop.mischief.check();
    expect(buddy().active, isFalse);
    expect(home.out, isFalse);
    expect(home.returns.last, home.at.$1);
    expect(stage.showing, isEmpty);
    expect(buddy().every, isNull);
    fullScreen = false;
    t.desktop.mischief.check();
    expect(buddy().active, isTrue, reason: 'out again once the screen is free');
    shown = false;
    mischief.surfaceChanged();
    expect(buddy().active, isFalse);
    expect(home.out, isFalse);
    await done(tester);
  });

  testWidgets('quiet hours or the switch turned off: it runs home, then it’s on the taskbar again', (tester) async {
    begin();
    pointer = (1500, 300);
    await run(tester, 3);
    t.desktop.settings.quietHours = const QuietHours(enabled: true, startMinute: 14 * 60, endMinute: 16 * 60);
    expect(buddy().mode, BuddyMode.home);
    expect(home.out, isTrue, reason: 'on its way');
    await run(tester, CursorBuddy.homeAtMost + 0.5);
    expect(home.out, isFalse);
    expect(buddy().active, isFalse);
    expect(stage.showing, isEmpty);
    expect(buddy().every, isNull);
    await done(tester);
  });

  testWidgets('onto a display at another scale: Mochi is drawn at that scale there', (tester) async {
    begin();
    pointer = (3000, 700);
    await run(tester, 4);
    final (x, _) = buddy().feet;
    expect(x, greaterThan(1920), reason: 'over on the side display');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await run(tester, 0.3, step: CursorBuddy.sitEvery);
    expect(mischief.pet!.sprites.context, startsWith('pet|1.5|'));
    await done(tester);
  });

  testWidgets('the pointer is only read, never moved', (tester) async {
    begin();
    await run(tester, 1);
    expect(reads, greaterThan(10));
    expect(pointer, (900, 500), reason: 'nothing here can move it');
    expect(stage.calls.where((call) => call != 'show' && call != 'sprites' && call != 'hide' && call != 'raise' && call != 'drop'), isEmpty);
    await done(tester);
  });

  testWidgets('while Mochi is out with nobody left on the taskbar, the pet’s own view draws nothing', (tester) async {
    begin(on: false);
    Widget view({required bool away}) => Directionality(
      textDirection: TextDirection.ltr,
      child: MochiView(world: t.desktop.world, sessions: t.desktop.sessions, lastActivity: () => now, petAway: away),
    );
    await tester.pumpWidget(view(away: false));
    final state = tester.state<MochiViewState>(find.byType(MochiView));
    expect(state.fps, greaterThan(0));
    await tester.pumpWidget(view(away: true));
    await tester.pump();
    expect(state.fps, 0, reason: 'no frames for a Mochi drawn elsewhere');
    await tester.pumpWidget(view(away: false));
    await tester.pump();
    expect(state.fps, greaterThan(0), reason: 'back');
    await tester.pumpWidget(const SizedBox());
    await done(tester);
  });
}
