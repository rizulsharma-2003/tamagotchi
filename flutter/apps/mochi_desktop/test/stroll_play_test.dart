// Mochi playing on its own on the taskbar, as the Mac's menu-bar Mochi does (docs/SPRINT_2.md, the taskbar stroll's
// ambient play): zoomies, a ball, yarn, a butterfly, a leaf. The plan (ui/pet/stroller.dart) against the Mac's weights
// and the free stretches, the toys drawn by the pet's view, and the window making room for them
// (ui/pet/taskbar_stroll.dart).

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/system.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

const _play = {StrollActivity.zoomies, StrollActivity.butterfly, StrollActivity.ball, StrollActivity.yarn, StrollActivity.leaf};
const _zones = [StrollLine(100, 700), StrollLine(900, 1500)];

/// Plays [stroller] from [from] to [to] seconds in [mode], collecting every segment it plans.
Set<StrollSegment> _run(Stroller stroller, double from, double to, {StrollMode mode = StrollMode.free, double step = 0.25}) {
  final seen = <StrollSegment>{};
  for (var t = from; t <= to; t += step) {
    stroller.update(t, mode: mode);
    seen.addAll(stroller.segments);
  }
  return seen;
}

/// Lives [stroller] from [from] to [to] seconds, looking at it each step (the plan is pruned behind the clock, so it can only
/// be looked at as time passes).
void _live(Stroller stroller, double from, double to, void Function(double t) each, {StrollMode mode = StrollMode.free, double step = 0.05}) {
  for (var t = from; t <= to; t += step) {
    stroller.update(t, mode: mode);
    each(t);
  }
}

bool _inZone(List<StrollLine> zones, double x, [double slack = 0.5]) => zones.any((zone) => x >= zone.minX - slack && x <= zone.maxX + slack);

void main() {
  group('The plan', () {
    test('every play can be chosen in free mode, and is planned with its toy', () {
      final seen = <StrollActivity>{};
      final toys = <ScenePropKind>{};
      for (var seed = 0; seed < 80 && !(seen.containsAll(_play) && toys.length == 4); seed++) {
        final stroller = Stroller(random: Random(seed))..place(_zones, now: 0, x: 400);
        _live(stroller, 0, 1500, (t) {
          final sample = stroller.sample(t);
          if (_play.contains(sample.activity)) seen.add(sample.activity);
          toys.addAll(sample.props.map((toy) => toy.kind));
        }, step: 0.25);
      }
      expect(seen, containsAll(_play));
      expect(toys, {ScenePropKind.ball, ScenePropKind.yarn, ScenePropKind.butterfly, ScenePropKind.leaf}, reason: 'each with its toy');
    });

    test('the weights are the Mac\'s (wander 3, sniff 2, fidget 1.8, nap 0.45, zoomies 1, butterfly 1.2, ball 1, yarn 0.5, leaf 0.6)', () {
      final stroller = Stroller(random: Random(99))..place(_zones, now: 0, x: 400);
      const draws = 12000;
      final counts = <StrollActivity, int>{};
      for (var i = 0; i < draws; i++) {
        counts.update(stroller.chooseFreeActivity(), (n) => n + 1, ifAbsent: () => 1);
      }
      // Ours also has the trot (0.5) and a walk across to the other stretch (0.6), which the Mac's bar doesn't have.
      const weights = {
        StrollActivity.wander: 3.0,
        StrollActivity.sniff: 2.0,
        StrollActivity.fidget: 1.8,
        StrollActivity.nap: 0.45,
        StrollActivity.trot: 0.5,
        StrollActivity.cross: 0.6,
        StrollActivity.zoomies: 1.0,
        StrollActivity.butterfly: 1.2,
        StrollActivity.ball: 1.0,
        StrollActivity.yarn: 0.5,
        StrollActivity.leaf: 0.6,
      };
      final total = weights.values.reduce((a, b) => a + b);
      for (final MapEntry(key: activity, value: weight) in weights.entries) {
        expect((counts[activity] ?? 0) / draws, closeTo(weight / total, 0.012), reason: '${activity.name} is ${weight / total}');
      }
    });

    test('none while working, attending, asleep, paused or with animation effects off', () {
      for (final mode in [StrollMode.working, StrollMode.attending, StrollMode.asleep, StrollMode.paused, StrollMode.still]) {
        for (var seed = 0; seed < 6; seed++) {
          final stroller = Stroller(random: Random(seed))..place(_zones, now: 0, x: 400, mode: mode);
          for (final segment in _run(stroller, 0, 1800, mode: mode)) {
            expect(_play.contains(segment.activity), isFalse, reason: '${segment.activity.name} in ${mode.name}');
          }
          for (var t = 0.0; t < 1800; t += 0.5) {
            expect(stroller.sample(t).props, isEmpty, reason: mode.name);
          }
          expect(stroller.playRoom(900), isNull);
        }
      }
    });

    test('paused and still are modes of the mood: reactions paused outranks animation effects off, Claude needing you outranks both', () {
      expect(StrollMode.of(PetMood.relaxed, reducedMotion: false, paused: true), StrollMode.paused);
      expect(StrollMode.of(PetMood.relaxed, reducedMotion: true, paused: true), StrollMode.paused);
      expect(StrollMode.of(PetMood.needsYou, reducedMotion: false, paused: true), StrollMode.attending);
      expect(StrollMode.of(PetMood.napping, reducedMotion: false, paused: true), StrollMode.asleep);
      expect(StrollMode.of(PetMood.relaxed, reducedMotion: true), StrollMode.still);
    });

    test('paused: Mochi sits where it is for as long as it lasts', () {
      final stroller = Stroller(random: Random(3))..place(_zones, now: 0, x: 400, mode: StrollMode.paused);
      final x = stroller.sample(0).x;
      _run(stroller, 0, 600, mode: StrollMode.paused);
      expect(stroller.sample(600).x, x);
      expect(stroller.sample(600).animation, PetAnimation.sit);
      expect(stroller.nextChange(600), isNull, reason: 'nothing wakes a timer');
    });

    test('the toys stay inside the free stretch Mochi is in (never over a button); the zoomies may cross the buttons, ending over free room', () {
      var toys = 0;
      for (var seed = 0; seed < 40; seed++) {
        final stroller = Stroller(random: Random(seed))..place(_zones, now: 0, x: 300 + seed * 20);
        final seen = <StrollSegment>{};
        _live(stroller, 0, 1500, (t) {
          seen.addAll(stroller.segments);
          final sample = stroller.sample(t);
          if (!sample.travelling || _play.contains(sample.activity) && sample.activity != StrollActivity.zoomies) expect(_inZone(_zones, sample.x), isTrue);
          for (final toy in sample.props) {
            toys++;
            // (A flutter or a drift sways a few pixels either side of its path.)
            expect(_inZone(_zones, toy.x, 14), isTrue, reason: '${toy.kind.name} at ${toy.x}');
          }
        }, step: 0.1);
        for (final segment in seen) {
          expect(_inZone(_zones, segment.fromX) && _inZone(_zones, segment.toX), isTrue, reason: '$segment');
          if (segment.travels && !segment.hop && !segment.crosses) {
            expect(_zones.any((zone) => _inZone([zone], segment.fromX) && _inZone([zone], segment.toX)), isTrue, reason: 'no crossing: $segment');
          }
        }
      }
      expect(toys, greaterThan(500));
    });

    test('a stretch too short for an activity skips it: zoomies fit a 320-wide one, the butterfly (336) does not, nothing fits a short one', () {
      final medium = Stroller(random: Random(1))..place(const [StrollLine(100, 420)], now: 0, x: 200);
      final picks = {for (var i = 0; i < 2000; i++) medium.chooseFreeActivity()};
      expect(picks, contains(StrollActivity.zoomies));
      expect(picks, contains(StrollActivity.leaf));
      expect(picks, isNot(contains(StrollActivity.butterfly)));
      final short = Stroller(random: Random(2))..place(const [StrollLine(100, 250)], now: 0, x: 200);
      final shortPicks = {for (var i = 0; i < 2000; i++) short.chooseFreeActivity()};
      expect(shortPicks.intersection(_play), isEmpty);
      for (final segment in _run(short, 0, 3000)) {
        expect(_play.contains(segment.activity), isFalse);
      }
    });

    test('the window\'s room covers every toy: how far it gets from Mochi and how high, with a margin', () {
      var played = 0;
      for (var seed = 0; seed < 30; seed++) {
        final stroller = Stroller(random: Random(seed))..place(_zones, now: 0, x: 500);
        _live(stroller, 0, 1500, (t) {
          final sample = stroller.sample(t);
          if (sample.props.isEmpty) return;
          played++;
          final room = stroller.playRoom(t);
          expect(room, isNotNull, reason: 'the window has made room at $t');
          for (final toy in sample.props) {
            expect((toy.x - sample.x).abs(), lessThanOrEqualTo(room!.x - 8), reason: '${toy.kind.name} beyond the window sideways');
            expect(toy.y, lessThanOrEqualTo(room.up - 8), reason: '${toy.kind.name} above the window');
          }
        });
      }
      expect(played, greaterThan(1000));
    });

    test('the room is made a moment before the first toy and given back a moment after the last', () {
      final stroller = Stroller(random: Random(4))..place(_zones, now: 0, x: 500);
      double? first, last;
      var before = false, after = false, early = false, late = false;
      _live(stroller, 0, 400, (t) {
        final shows = stroller.sample(t).props.isNotEmpty;
        final room = stroller.playRoom(t) != null;
        if (last != null && t > last! + 0.8 && !shows) return;
        if (shows) {
          first ??= t;
          last = t;
          expect(room, isTrue);
        }
        if (!shows && first == null && !room) early = true;
        if (!shows && first != null && room && t < last! + 0.3) after = true;
        if (!shows && first != null && room && t >= last! + 0.5) late = true;
        if (!shows && first == null && room) before = true;
      });
      expect(first, isNotNull);
      expect(before, isTrue, reason: 'room made before the first toy shows');
      expect(after, isTrue, reason: 'and kept a moment after the last');
      expect(early, isTrue);
      expect(late, isFalse, reason: 'but not for long');
    });

    test('a toy goes when the play is interrupted (Claude\'s news, a drag)', () {
      for (var seed = 0; seed < 40; seed++) {
        final stroller = Stroller(random: Random(seed))..place(_zones, now: 0, x: 500);
        double? at;
        _live(stroller, 0, 1500, (t) {
          if (at == null && stroller.sample(t).props.isNotEmpty) {
            at = t;
            stroller.react(t, 3);
          }
        });
        if (at == null) continue;
        expect(stroller.sample(at! + 0.1).props, isEmpty);
        expect(stroller.playRoom(at! + 3.5), isNull);
        return;
      }
      fail('no play in 40 seeds');
    });
  });

  group('On the taskbar', () {
    late TestDesktop t;
    late FakePetWindow window;
    late FakeShell shell;
    late FakeTaskbar taskbar;

    setUp(() {
      t = TestDesktop.make();
      window = FakePetWindow();
      shell = FakeShell(petWindow: window);
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    });

    tearDown(() => t.dispose());

    final strolls = <TaskbarStroll>[];
    final disposables = <void Function()>[];
    void playTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final stroll in strolls) {
          stroll.dispose();
        }
        strolls.clear();
        for (final dispose in disposables) {
          dispose();
        }
        disposables.clear();
      }
    });

    Future<TaskbarStroll> start(WidgetTester tester, {SystemMotion? motion, int seed = 7}) async {
      final stroll = TaskbarStroll(
        shell: shell,
        taskbar: taskbar,
        settings: t.desktop.settings,
        motion: motion ?? t.desktop.motion,
        cues: t.desktop.cues,
        rhythm: t.desktop.rhythm,
        mischief: t.desktop.mischief,
        clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        random: Random(seed),
      );
      strolls.add(stroll);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      return stroll;
    }

    Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.1, void Function()? each}) async {
      for (var s = 0.0; s < seconds; s += step) {
        await tester.pump(Duration(microseconds: (step * 1e6).round()));
        each?.call();
      }
    }

    playTest('the window makes room for the toy while it plays, centred on Mochi with its feet on the same line, and gives it back', (tester) async {
      final stroll = await start(tester, seed: 5);
      final box = stroll.box;
      final bottom = window.frames.last.bottom;
      var grown = false;
      var widest = 0;
      var tallest = 0;
      var toysSeen = false;
      await elapse(
        tester,
        900,
        step: 0.25,
        each: () {
          final sample = stroll.sample();
          if (sample != null && sample.props.isNotEmpty) toysSeen = true;
          final frame = stroll.frame!;
          expect(frame.bottom, bottom, reason: 'its feet stay where they are');
          if (frame.width > box.width * stroll.stage!.scale + 1) {
            grown = true;
            widest = frame.width > widest ? frame.width : widest;
            tallest = frame.height > tallest ? frame.height : tallest;
            expect(stroll.playRoom, isNotNull);
          }
          if (sample != null && !stroll.moving && stroll.playRoom != null) {
            // Centred on Mochi (Mochi is drawn in the middle of its window).
            expect((frame.left + frame.right) / 2 / stroll.stage!.scale, closeTo(sample.x, 3));
            // And big enough for every toy in play.
            for (final toy in sample.props) {
              expect((toy.x - sample.x).abs() * stroll.stage!.scale, lessThan(frame.width / 2), reason: '${toy.kind.name} inside the window');
              expect(toy.y * stroll.stage!.scale, lessThan(frame.height), reason: '${toy.kind.name} below the window\'s top');
            }
          }
        },
      );
      expect(toysSeen, isTrue, reason: 'Mochi played in 15 minutes');
      expect(grown, isTrue);
      expect(widest, greaterThan(box.width), reason: 'wider around Mochi');
      expect(tallest, greaterThanOrEqualTo(box.height.round()));
      // Quiet again: the window is Mochi's box once more.
      stroll.stroller.react(stroll.now(), 600);
      await elapse(tester, 1);
      expect(stroll.frame!.width, (box.width * stroll.stage!.scale).round());
      expect(stroll.playRoom, isNull);
    });

    playTest('no play with Windows animation effects off: Mochi stays put and the window stays its box', (tester) async {
      final motion = SystemMotion(read: () => true);
      disposables.add(motion.dispose);
      final stroll = await start(tester, motion: motion, seed: 5);
      await elapse(tester, 600, step: 0.5, each: () => expect(stroll.sample()!.props, isEmpty));
      expect(stroll.playRoom, isNull);
      expect(window.moves, isEmpty);
      expect(window.frames.map((frame) => frame.width).toSet(), hasLength(1));
    });

    playTest('no play while reactions are paused (and it plays again once they are back)', (tester) async {
      t.desktop.settings.pauseReactions = true;
      final stroll = await start(tester, seed: 5);
      final x = stroll.sample()!.x;
      await elapse(tester, 600, step: 0.5, each: () => expect(stroll.sample()!.props, isEmpty));
      expect(stroll.sample()!.x, x, reason: 'it sits where it is');
      expect(stroll.playRoom, isNull);
      expect(stroll.moving || stroll.waiting, isFalse, reason: 'and nothing runs for it');
      t.desktop.settings.pauseReactions = false;
      var played = false;
      await elapse(tester, 900, step: 0.25, each: () => played = played || stroll.sample()!.props.isNotEmpty);
      expect(played, isTrue);
    });

    playTest('nothing runs for it while nobody can see the screen', (tester) async {
      final stroll = await start(tester, seed: 5);
      await elapse(tester, 20);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
      await tester.pump();
      expect(stroll.anyTimer, isFalse);
      final moves = window.moves.length;
      final frames = window.frames.length;
      await tester.pump(const Duration(minutes: 5));
      expect(window.moves.length, moves);
      expect(window.frames.length, frames);
      expect(stroll.anyTimer, isFalse);
    });

    playTest('Mischief\'s cursor buddy and the play share the plan: the pointer arriving cuts a play short, toys and all', (tester) async {
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      final stroll = await start(tester, seed: 5);
      var toy = false;
      await elapse(
        tester,
        900,
        step: 0.1,
        each: () {
          if (toy || stroll.sample()!.props.isEmpty) return;
          toy = true;
          // The pointer comes over the taskbar right where Mochi plays.
          final bar = stroll.stage!.bar;
          taskbar.pointer = ((stroll.sample()!.x * stroll.stage!.scale).round() + 30, bar.top + bar.height ~/ 2);
        },
      );
      expect(toy, isTrue);
      await elapse(tester, 1);
      expect(stroll.sample()!.props, isEmpty, reason: 'the toy went with the play');
      expect(stroll.stroller.buddying, isTrue);
    });
  });

  group('Drawn', () {
    late TestDesktop t;

    setUp(() => t = TestDesktop.make());
    tearDown(() => t.dispose());

    /// The view's pixels for a sample, in a window 300 by 80 logical pixels.
    Future<(Uint8List, int)> draw(WidgetTester tester, StrollSample sample) async {
      final key = GlobalKey();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(300, 80);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(300, 80)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 80,
                child: RepaintBoundary(
                  key: key,
                  child: MochiView(
                    world: t.desktop.world,
                    sessions: t.desktop.sessions,
                    lastActivity: () => t.desktop.sessions.now,
                    fill: SurfaceSizes.taskbarFill,
                    feet: SurfaceSizes.taskbarFeet,
                    detail: RenderDetail.tiny,
                    stroll: () => sample,
                    time: () => 2.0,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final view = tester.state<MochiViewState>(find.byType(MochiView));
      final pixels = await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      return (pixels!, view.fps.round());
    }

    /// Opaque pixels in the box [left]…[right] × [top]…[bottom] (window pixels, 300 wide).
    int inked(Uint8List pixels, int left, int top, int right, int bottom) {
      var n = 0;
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          if (pixels[(y * 300 + x) * 4 + 3] > 40) n++;
        }
      }
      return n;
    }

    testWidgets('the toys show: a ball beside Mochi, a butterfly above it, in the room the window made, at the walk\'s frame rate', (tester) async {
      const base = StrollSample(x: 500, facing: 1, animation: PetAnimation.watch, animationTime: 2.0, activity: StrollActivity.ball);
      final (bare, restFps) = await draw(tester, base);
      expect(restFps, lessThan(25), reason: 'a calm loop is not drawn at the walk\'s rate');
      // A ball 70 px to Mochi's right, resting on the taskbar; Mochi is in the middle of the window (x 150).
      final ball = StrollSample(
        x: 500,
        facing: 1,
        animation: PetAnimation.watch,
        animationTime: 2.0,
        activity: StrollActivity.ball,
        props: const [StrollPropSample(kind: ScenePropKind.ball, x: 570, y: 7, rotation: 0.3, opacity: 1, scale: 1.8, variant: 0)],
      );
      final (withBall, ballFps) = await draw(tester, ball);
      expect(inked(bare, 205, 40, 245, 80), 0, reason: 'nothing there without it');
      expect(inked(withBall, 205, 40, 245, 80), greaterThan(30), reason: 'the ball is drawn, well outside Mochi\'s own box');
      expect(ballFps, 25, reason: 'a toy in play: the walk\'s frame rate');
      // A butterfly well above Mochi's head.
      final butterfly = StrollSample(
        x: 500,
        facing: 1,
        animation: PetAnimation.watch,
        animationTime: 2.0,
        activity: StrollActivity.butterfly,
        props: const [StrollPropSample(kind: ScenePropKind.butterfly, x: 540, y: 48, rotation: 0.7, opacity: 1, scale: 1.5, variant: 0)],
      );
      final (withButterfly, _) = await draw(tester, butterfly);
      expect(inked(bare, 170, 0, 230, 25), 0);
      expect(inked(withButterfly, 170, 0, 230, 25), greaterThan(20), reason: 'the butterfly is drawn above the taskbar-sized box');
      // Faded out: nothing.
      final gone = StrollSample(
        x: 500,
        facing: 1,
        animation: PetAnimation.watch,
        animationTime: 2.0,
        activity: StrollActivity.ball,
        props: const [StrollPropSample(kind: ScenePropKind.ball, x: 570, y: 7, rotation: 0.3, opacity: 0, scale: 1.8, variant: 0)],
      );
      final (faded, _) = await draw(tester, gone);
      expect(inked(faded, 205, 40, 245, 80), 0);
    });
  });
}
