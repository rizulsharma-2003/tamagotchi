// Peekaboo on the taskbar (docs/SPRINT_2.md X3): with Mischief's switch on and Mochi free to wander alone, two minutes
// without input make it walk to a free spot and sink down into the taskbar until only its ears and eyes show, looking
// around now and then; input again pops it up with a happy bounce, once per away stretch. Anything else brings it out
// first. Only what shows takes clicks, and while it sits hidden nothing runs. Driven through the real stroll controller
// with a fake taskbar and window.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart' show Offset, Size, SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart' show PetAnimation;
import 'package:mochi_art/pose_tracks.dart' show PoseLibrary;
import 'package:mochi_art/pose_tracks.dart' show PoseLibrary;
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

void main() {
  late TestDesktop t;
  late FakePetWindow window;
  late FakeShell shell;
  late FakeTaskbar taskbar;
  final strolls = <TaskbarStroll>[];

  late PoseLibrary library;
  setUpAll(() => library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync()));

  setUp(() {
    t = TestDesktop.make();
    window = FakePetWindow();
    shell = FakeShell(petWindow: window);
    final reading = FakeTaskbar.bottomTaskbar();
    taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
    t.desktop.settings.mischief = const MischiefSettings(enabled: true);
  });

  tearDown(() => t.dispose());

  /// A test that takes its strolls down before it ends (their timers must not outlive the widget tree).
  void peekTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final stroll in strolls) {
        stroll.dispose();
      }
      strolls.clear();
    }
  });

  Future<TaskbarStroll> start(WidgetTester tester, {int seed = 7}) async {
    final stroll = TaskbarStroll(
      shell: shell,
      taskbar: taskbar,
      settings: t.desktop.settings,
      motion: t.desktop.motion,
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

  Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.1}) async {
    for (var s = 0.0; s < seconds; s += step) {
      await tester.pump(Duration(microseconds: (step * 1e6).round()));
    }
  }

  /// The PC has had no input for [seconds].
  void idleFor(double seconds) => t.desktop.rhythm.report(SystemActivity(idleSeconds: seconds));

  double sink(TaskbarStroll stroll) => stroll.sample()!.sink;

  /// Away for two minutes in free mode: Mochi has hidden.
  Future<TaskbarStroll> hidden(WidgetTester tester) async {
    final stroll = await start(tester);
    idleFor(130);
    await elapse(tester, 12);
    expect(stroll.stroller.hiding, isTrue);
    expect(sink(stroll), 1);
    return stroll;
  }

  group('hiding while you are away', () {
    peekTest('after two minutes idle in free mode it walks to a spot and sinks until only its ears and eyes show', (tester) async {
      final stroll = await start(tester);
      idleFor(100);
      await elapse(tester, 8);
      expect(stroll.stroller.hiding, isFalse, reason: 'not yet two minutes');
      expect(sink(stroll), 0);
      idleFor(125);
      var sawSinking = false;
      var walked = false;
      for (var i = 0; i < 150; i++) {
        await elapse(tester, 0.1);
        final s = sink(stroll);
        if (s > 0 && s < 1) sawSinking = true;
        if (stroll.sample()!.travelling) walked = true;
      }
      expect(stroll.stroller.hiding, isTrue);
      expect(sawSinking, isTrue, reason: 'it sinks gradually');
      expect(sink(stroll), 1);
      expect(walked || stroll.stroller.segments.any((s) => s.activity == StrollActivity.hide), isTrue);
      expect(stroll.sample()!.activity, StrollActivity.hide);
      final x = stroll.sample()!.x;
      expect(stroll.stage!.zones.any((z) => x >= z.minX - 1 && x <= z.maxX + 1), isTrue, reason: 'in a free stretch');
    });

    peekTest('it does not hide with the switch off, the master off, or in any mode but free', (tester) async {
      t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.peekaboo: false});
      var stroll = await start(tester);
      idleFor(200);
      await elapse(tester, 15);
      expect(stroll.stroller.hiding, isFalse, reason: 'its own switch is off');
      t.desktop.settings.mischief = const MischiefSettings();
      await elapse(tester, 15);
      expect(stroll.stroller.hiding, isFalse, reason: 'the master switch is off');
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      // Claude working, Claude needing you, a nap and paused reactions are not free mode.
      for (final mood in [PetMood.watching, PetMood.needsYou, PetMood.napping]) {
        stroll.mood = mood;
        await elapse(tester, 15);
        expect(stroll.stroller.hiding, isFalse, reason: 'mood ${mood.name}');
        expect(sink(stroll), 0);
      }
      stroll.mood = PetMood.relaxed;
      t.desktop.settings.pauseReactions = true;
      await elapse(tester, 15);
      expect(stroll.stroller.hiding, isFalse, reason: 'reactions paused');
      t.desktop.settings.pauseReactions = false;
      // A reaction (a pet, news) holds Mochi still: no hiding then either.
      stroll.stroller.react(stroll.now(), 20, attentive: true);
      await elapse(tester, 10);
      expect(stroll.stroller.hiding, isFalse, reason: 'reacting');
      stroll = strolls.first;
      expect(sink(stroll), 0);
    });

    peekTest('when you are back it pops up with a happy bounce, once per away stretch', (tester) async {
      final stroll = await hidden(tester);
      idleFor(1);
      await elapse(tester, 0.3);
      expect(stroll.stroller.hiding, isFalse);
      expect(stroll.stroller.segments.any((s) => s.animation == PetAnimation.happyBounce), isTrue, reason: 'the happy bounce');
      await elapse(tester, 3);
      expect(sink(stroll), 0, reason: 'standing again');
      // Back at the PC for a while, then away again: a new away stretch, and it hides again.
      idleFor(3);
      await elapse(tester, 1);
      idleFor(130);
      await elapse(tester, 12);
      expect(stroll.stroller.hiding, isTrue, reason: 'a new away stretch');
    });

    peekTest('the pointer moving pops it up before the rhythm has noticed', (tester) async {
      final stroll = await hidden(tester);
      taskbar.pointer = (300, 300);
      await elapse(tester, 0.3);
      expect(stroll.stroller.hiding, isTrue, reason: 'a pointer that was just there is not input');
      taskbar.pointer = (320, 310);
      await elapse(tester, 0.3);
      expect(stroll.stroller.hiding, isFalse);
      expect(stroll.stroller.segments.any((s) => s.animation == PetAnimation.happyBounce), isTrue);
      // The rhythm's reading is a few seconds old and still says away: not hidden again in the same stretch.
      await elapse(tester, 20);
      expect(stroll.stroller.hiding, isFalse, reason: 'once per away stretch');
    });

    peekTest('anything else brings it up first: Claude needing you, a reaction, a nap, the switch going off', (tester) async {
      for (final cut in <(String, void Function(TaskbarStroll))>[
        ('Claude needs you', (s) => s.mood = PetMood.needsYou),
        ('a nap', (s) => s.mood = PetMood.napping),
        ('a reaction', (s) => s.stroller.react(s.now(), 3, attentive: true)),
        ('the switch going off', (_) => t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.peekaboo: false})),
      ]) {
        final stroll = await hidden(tester);
        cut.$2(stroll);
        await elapse(tester, 1.5);
        expect(stroll.stroller.hiding, isFalse, reason: cut.$1);
        final risen = stroll.sink(tester);
        expect(risen, lessThan(1), reason: '${cut.$1}: it is coming up');
        await elapse(tester, 3);
        expect(sink(stroll), 0, reason: '${cut.$1}: standing');
        stroll.dispose();
        strolls.remove(stroll);
        t.desktop.settings.mischief = const MischiefSettings(enabled: true);
        idleFor(1);
        await tester.pump();
      }
    });
  });

  group('clicks and perf while hidden', () {
    peekTest('only what shows takes clicks: on it Mochi takes them (the pet opens the popover as ever)', (tester) async {
      final stroll = await hidden(tester);
      final frame = stroll.frame!;
      final body = stroll.bodies().single;
      expect(body.bottom, frame.bottom);
      expect(body.height, lessThan(frame.height * 0.5), reason: 'just the top of Mochi');
      taskbar.pointer = ((body.left + body.right) ~/ 2, body.bottom - 2);
      await elapse(tester, 0.4);
      expect(window.clickThrough.last, isFalse);
      expect(stroll.stroller.hiding, isTrue, reason: 'a pointer that arrives is not input yet');
    });

    peekTest('above what shows, clicks go through to the taskbar and the desktop', (tester) async {
      final stroll = await hidden(tester);
      final body = stroll.bodies().single;
      taskbar.pointer = ((body.left + body.right) ~/ 2, body.top - 6);
      await elapse(tester, 0.4);
      expect(window.clickThrough.last, isTrue);
    });

    peekTest('no frames while it sits hidden: no frame timer, the view draws nothing, and the stroll only wakes it for a look around', (tester) async {
      final stroll = await hidden(tester);
      expect(stroll.moving, isFalse, reason: 'no frame timer');
      var beats = 0;
      stroll.beat.addListener(() => beats++);
      await elapse(tester, 6);
      expect(stroll.moving, isFalse);
      expect(beats, lessThanOrEqualTo(4), reason: 'a wake for each change of the plan only');
      // The view: fully sunk and still is no frames; sinking or looking around is.
      const still = StrollSample(x: 0, facing: 1, animation: PetAnimation.sit, animationTime: 0, activity: StrollActivity.hide, sink: 1);
      expect(MochiView.frameRate(mood: PetMood.relaxed, roam: still, small: true), 0);
      const sinking = StrollSample(x: 0, facing: 1, animation: PetAnimation.sit, animationTime: 0, activity: StrollActivity.hide, sink: 0.5);
      expect(MochiView.frameRate(mood: PetMood.relaxed, roam: sinking, small: true), 25);
      const looking = StrollSample(x: 0, facing: 1, animation: PetAnimation.lookAround, animationTime: 0, activity: StrollActivity.hide, oneShot: true, sink: 1);
      expect(MochiView.frameRate(mood: PetMood.relaxed, roam: looking, small: true), 24);
    });

    peekTest('nothing runs while nobody can see the screen', (tester) async {
      final stroll = await hidden(tester);
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 200, displaysAsleep: true));
      await elapse(tester, 1);
      expect(stroll.anyTimer, isFalse);
      expect(stroll.watchingPointer, isFalse);
    });
  });

  testWidgets('in the app: a click on the part that shows opens the popover as usual', (tester) async {
    tester.view.physicalSize = SurfaceSizes.pet;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      DesktopApp(
        desktop: t.desktop,
        shell: shell,
        taskbar: taskbar,
        library: Future.value(library),
        strollClock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        strollRandom: Random(4),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
    idleFor(130);
    for (var i = 0; i < 130; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final stroll = state.stroll;
    expect(stroll.stroller.hiding, isTrue);
    expect(stroll.sample()!.sink, 1);
    final frame = stroll.frame!;
    tester.view.physicalSize = Size(frame.width.toDouble(), frame.height.toDouble());
    await tester.pump(const Duration(milliseconds: 100));
    final view = tester.widget<MochiView>(find.byType(MochiView));
    expect(view.stroll!.call()!.sink, 1, reason: 'the view draws it sunk');
    final box = tester.getRect(find.byType(MochiView));
    await tester.tapAt(box.bottomCenter - const Offset(0, 3));
    await tester.pump();
    final window = shell.petWindow!.current!;
    tester.view.physicalSize = Size(window.width.toDouble(), window.height.toDouble());
    for (var ms = 0; ms < 800; ms += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.surface, Surface.popover);
    await tester.pumpWidget(const SizedBox());
  });

  test('the stroll plan sinks and looks around on its own, and every cut of it comes up first', () {
    final stroller = Stroller(random: Random(3));
    stroller.place(const [StrollLine(100, 500)], now: 0, x: 200);
    expect(stroller.hide(0), isTrue);
    expect(stroller.hide(0), isFalse, reason: 'already hiding');
    var looked = false;
    for (var t = 0.0; t < 120; t += 0.5) {
      stroller.update(t, mode: StrollMode.free);
      final s = stroller.sample(t);
      if (s.activity == StrollActivity.hide && s.animation == PetAnimation.lookAround) looked = true;
    }
    expect(looked, isTrue, reason: 'it looks around now and then');
    expect(stroller.sample(119).sink, 1);
    // A plan cut while sunk (here a drag) rises first.
    stroller.react(120, double.infinity);
    expect(stroller.hiding, isFalse);
    expect(stroller.sample(120.01).sink, greaterThan(0.9));
    expect(stroller.sample(121).sink, 0);
  });
}

extension on TaskbarStroll {
  /// How far down Mochi is now.
  double sink(WidgetTester tester) => sample()!.sink;
}
