// Multi-monitor roaming (docs/SPRINT_2.md X8): Mochi walks to the next display now and then and comes home, follows the
// display you work on after a couple of minutes (and comes back when you do), is drawn at each display's own scale,
// goes home at once when a display is unplugged, and does nothing while Mischief says no or nobody can see the screen
// (no timers then). A fake stage reports two or three displays.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/displays.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect;
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart' show PetHome;
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';
import 'package:mochi_desktop/src/ui/stage/screen_roamer.dart';

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

/// A "random" that always says [value] (0: it's lucky now; 0.99: never).
class _Dice implements math.Random {
  double value = 0.99;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

void main() {
  const third = DisplayArea(
    key: r'\\.\DISPLAY3 1280x1024',
    monitor: PixelRect(4480, 0, 5760, 1024),
    workArea: PixelRect(4480, 0, 5760, 984),
    scale: 1,
  );
  const main = FakeDisplays.main1080, side = FakeDisplays.side1440;

  late TestDesktop t;
  late FakeNativeStage stage;
  late _Home home;
  late FakeDisplays displays;
  late _Dice dice;
  late MischiefStage mischief;
  var shown = true;
  var fullScreen = false;
  var foregroundReads = 0;

  setUp(() {
    shown = true;
    fullScreen = false;
    t = TestDesktop.make(clock: () => DateTime(2026, 11, 8, 15), fullScreen: () => fullScreen, activity: const SystemActivity(idleSeconds: 1));
    t.desktop.rhythm.sample();
    stage = FakeNativeStage();
    home = _Home();
    dice = _Dice();
    displays = FakeDisplays([main, side]);
  });

  tearDown(() async {
    mischief.dispose();
    await t.dispose();
  });

  ScreenRoamer roamer() => mischief.roamer!;

  void begin({bool on = true}) {
    mischief = MischiefStage(
      desktop: t.desktop,
      stage: stage,
      displays: displays,
      cursor: () => null,
      home: home,
      shown: () => shown,
      random: dice,
    );
    t.desktop.mischief.start();
    mischief.start();
    if (on) t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.cursorBuddy: false});
  }

  Future<void> run(WidgetTester tester, double seconds, {Duration step = const Duration(milliseconds: 100)}) async {
    final steps = (seconds * 1000 / step.inMilliseconds).ceil();
    for (var i = 0; i < steps; i++) {
      await tester.pump(step);
    }
  }

  Future<void> done(WidgetTester tester) async {
    mischief.roamer?.stop();
    t.desktop.mischief.stop();
    await tester.pump();
  }

  testWidgets('it waits for Mischief and its own switch, and with one display it never looks at anything', (tester) async {
    dice.value = 0;
    begin(on: false);
    await run(tester, 10);
    expect(roamer().active, isFalse);
    t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.cursorBuddy: false, MischiefExtra.roamScreens: false});
    await run(tester, 10);
    expect(roamer().active, isFalse, reason: 'its own switch is off');
    expect(roamer().watching, isNull);
    t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.cursorBuddy: false});
    displays.displays = [main];
    await run(tester, 20);
    expect(roamer().active, isFalse, reason: 'nowhere to go');
    expect(roamer().watching, ScreenRoamer.watchEvery);
    await done(tester);
  });

  testWidgets('now and then it walks along the bottom to the next display, lands on its floor at its scale, stays, and comes home', (tester) async {
    begin();
    await run(tester, 8);
    expect(roamer().active, isFalse, reason: 'not lucky');
    dice.value = 0;
    await run(tester, 4.1);
    expect(roamer().active, isTrue);
    expect(home.out, isTrue);
    dice.value = 0.99;
    expect((roamer().feet.$1 - home.at.$1).abs(), lessThan(40), reason: 'from where it stood on the taskbar');
    expect(roamer().feet.$2, home.at.$2);
    // Along the bottom of the main screen to its edge...
    await run(tester, 8);
    final (x, y) = roamer().feet;
    expect(roamer().on!.key, main.key);
    expect(x, greaterThan(300));
    expect(y, 1068, reason: 'along the taskbar');
    // ...and on to the next display (no taskbar: its bottom edge), at its own scale.
    await run(tester, 30);
    expect(roamer().on!.key, side.key);
    expect(roamer().phase, RoamPhase.staying);
    expect(roamer().feet.$2, 1440 - 3, reason: 'its bottom edge');
    expect(roamer().feet.$1, greaterThan(1920));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await run(tester, 0.5);
    expect(mischief.pet!.sprites.context, startsWith('pet|1.5|'));
    expect(stage.showing[mischief.pet!.actor], isNotNull);
    expect(roamer().every, ScreenRoamer.standEvery, reason: 'eight frames a second while it stands');
    // A while later it comes home, walking back.
    await run(tester, ScreenRoamer.lingerFor + 1);
    expect(roamer().phase, RoamPhase.coming);
    await run(tester, 60);
    expect(roamer().active, isFalse);
    expect(home.out, isFalse);
    expect(home.returns.last, home.at.$1);
    expect(stage.showing, isEmpty);
    expect(roamer().every, isNull);
    await done(tester);
  });

  testWidgets('a display with a taskbar along its bottom: Mochi stands on that taskbar', (tester) async {
    displays.displays = [main, third];
    dice.value = 0;
    begin();
    await run(tester, 4.1);
    dice.value = 0.99;
    await run(tester, 28);
    expect(roamer().on!.key, third.key);
    expect(roamer().feet.$2, 984 + 30, reason: 'on the taskbar (three quarters of the way down it)');
    await done(tester);
  });

  testWidgets('you work on another display for two minutes: it goes there and stays; back on the main one, it comes home', (tester) async {
    begin();
    displays.front = side;
    await run(tester, 100);
    expect(roamer().active, isFalse, reason: 'not yet');
    await run(tester, 25);
    expect(roamer().active, isTrue, reason: 'two minutes on the other display');
    await run(tester, 40);
    expect(roamer().on!.key, side.key);
    expect(roamer().phase, RoamPhase.staying);
    await run(tester, 300);
    expect(roamer().phase, RoamPhase.staying, reason: 'it stays while you do');
    expect(roamer().active, isTrue);
    displays.front = main;
    await run(tester, 12);
    expect(roamer().phase, RoamPhase.coming);
    await run(tester, 40);
    expect(roamer().active, isFalse);
    expect(home.returns.last, home.at.$1);
    await done(tester);
  });

  testWidgets('a short visit to the other display does not send it', (tester) async {
    begin();
    displays.front = side;
    await run(tester, 60);
    displays.front = main;
    await run(tester, 200);
    expect(roamer().active, isFalse);
    await done(tester);
  });

  testWidgets('three displays: it follows you on to the third, walking through the middle one', (tester) async {
    displays.displays = [main, side, third];
    begin();
    displays.front = side;
    await run(tester, 130);
    await run(tester, 40);
    expect(roamer().on!.key, side.key);
    displays.front = third;
    await run(tester, 130);
    expect(roamer().active, isTrue);
    await run(tester, 40);
    expect(roamer().on!.key, third.key);
    expect(roamer().phase, RoamPhase.staying);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await run(tester, 0.5);
    expect(mischief.pet!.sprites.context, startsWith('pet|1.0|'));
    await done(tester);
  });

  testWidgets('a display unplugged mid-walk: Mochi is home on the main display at once', (tester) async {
    dice.value = 0;
    begin();
    await run(tester, 4.1);
    dice.value = 0.99;
    await run(tester, 5);
    expect(roamer().active, isTrue);
    displays.displays = [main];
    stage.displaysChangedNow();
    expect(roamer().active, isFalse);
    expect(home.out, isFalse);
    expect(home.returns.last, home.at.$1, reason: 'back on its own taskbar');
    expect(stage.showing, isEmpty);
    await run(tester, 10);
    expect(roamer().active, isFalse);
    await done(tester);
  });

  testWidgets('a display unplugged while it stays there (no event: the next frame sees it)', (tester) async {
    begin();
    displays.front = side;
    await run(tester, 170);
    expect(roamer().on?.key, side.key);
    displays.displays = [main];
    await run(tester, 1);
    expect(roamer().active, isFalse);
    expect(home.out, isFalse);
    await done(tester);
  });

  testWidgets('the main display itself changing: it comes home without a spot to go back to', (tester) async {
    dice.value = 0;
    begin();
    await run(tester, 4.1);
    dice.value = 0.99;
    await run(tester, 2);
    displays.displays = [side];
    stage.displaysChangedNow();
    expect(home.out, isFalse);
    expect(home.returns.last, isNull);
    await done(tester);
  });

  testWidgets('a full-screen app, or Mochi’s window opening: home at once; quiet hours: it walks home', (tester) async {
    dice.value = 0;
    begin();
    await run(tester, 4.1);
    dice.value = 0.99;
    await run(tester, 5);
    fullScreen = true;
    t.desktop.mischief.check();
    expect(roamer().active, isFalse);
    expect(home.out, isFalse);
    expect(roamer().watching, isNull);
    expect(roamer().every, isNull);
    fullScreen = false;
    t.desktop.mischief.check();
    expect(roamer().watching, isNotNull);
    dice.value = 0;
    await run(tester, 4.1);
    dice.value = 0.99;
    expect(roamer().active, isTrue);
    shown = false;
    mischief.surfaceChanged();
    expect(roamer().active, isFalse);
    expect(home.out, isFalse);
    shown = true;
    mischief.surfaceChanged();
    t.desktop.settings.mischief = const MischiefSettings(enabled: true, extras: {MischiefExtra.cursorBuddy: false, MischiefExtra.roamScreens: false});
    expect(roamer().watching, isNull);
    await done(tester);
  });

  testWidgets('nobody can see the screen: no timers at all, nothing drawn; when it is back Mochi carries on', (tester) async {
    displays.front = side;
    begin();
    await run(tester, 130);
    await run(tester, 5);
    expect(roamer().active, isTrue);
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
    expect(roamer().paused, isTrue);
    expect(roamer().watching, isNull);
    expect(roamer().every, isNull);
    expect(stage.showing, isEmpty);
    final before = stage.shots.length;
    await run(tester, 60);
    expect(stage.shots.length, before, reason: 'nothing is drawn');
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 0));
    expect(roamer().paused, isFalse);
    expect(roamer().watching, ScreenRoamer.watchEvery);
    await run(tester, 60);
    expect(roamer().on!.key, side.key);
    await done(tester);
  });

  testWidgets('it is cheap: the foreground window is read once every few seconds, not at all while nobody can see', (tester) async {
    displays = _Counting([main, side], () => foregroundReads++);
    foregroundReads = 0;
    begin();
    await run(tester, 40);
    expect(foregroundReads, inInclusiveRange(9, 10), reason: 'every four seconds');
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
    final before = foregroundReads;
    await run(tester, 60);
    expect(foregroundReads, before);
    await done(tester);
  });
}

class _Counting extends FakeDisplays {
  _Counting(List<DisplayArea> list, this.onRead) : super(list);

  final void Function() onRead;

  @override
  DisplayArea? foreground() {
    onRead();
    return super.foreground();
  }
}
