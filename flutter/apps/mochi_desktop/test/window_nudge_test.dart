// Window nudges (docs/SPRINT_2.md X2), the put-back contract: every motion ends exactly at home; the foreground window is
// never moved; a user's move or resize stops a nudge with nothing put back; a window lagging behind its own async moves is waited for and then sent home; a
// refusing window is skipped; every abort goes home; the journal is written first, kept up, deleted, and replayed at
// startup; every rule on which windows qualify; one at a time. A fake mover and the test clock (it moves with `pump`).

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/json_store.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/window_nudge.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect;

import 'support/fake_mover.dart';
import 'support/fakes.dart';

void main() {
  const home = PixelRect(400, 300, 1100, 800);
  const other = PixelRect(1200, 200, 1800, 700);

  late FakeMover mover;
  late MemoryJsonStore store;
  late WindowNudger nudger;
  late List<String> log;
  var allowed = true;

  setUp(() {
    mover = FakeMover({11: FakeWin(home), 12: FakeWin(other)});
    store = MemoryJsonStore();
    log = [];
    allowed = true;
    nudger = WindowNudger(mover: mover, store: store, allowed: () => allowed, clock: testSeconds, log: log.add);
  });

  tearDown(() => nudger.dispose());

  /// A test that leaves nothing running (a nudge in flight is put back and its read back done before the test ends).
  void nudgeTest(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      await body(tester);
      nudger.putBack();
      await tester.pump(const Duration(milliseconds: 300));
    });
  }

  Future<void> run(WidgetTester tester, double seconds) async {
    for (var i = 0; i < (seconds * 1000 / 33).ceil(); i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
  }

  /// A few steps, so the window is away from home.
  Future<void> away(WidgetTester tester, {NudgeKind kind = NudgeKind.shove}) async {
    expect(nudger.start(11, kind), isTrue);
    await run(tester, 0.3);
    expect(mover.windows[11]!.rect, isNot(home), reason: 'it moved');
  }

  group('the motions', () {
    test('wobble: 3 px down, back, 1 px down, back, in 350 ms, scaled by the display', () {
      final m = NudgeMotion.wobble();
      expect(m.duration, 0.35);
      final dy = [for (var t = 0.0; t < 0.35; t += 0.01) m.at(t).$2];
      expect(dy.every((v) => v >= 0 && v <= 3), isTrue);
      expect(dy.reduce((a, b) => a > b ? a : b), 3);
      expect(dy.every((v) => m.at(0.1).$1 == 0), isTrue);
      expect(m.at(0.09).$2, 3);
      expect(m.at(0.18).$2, 0, reason: 'back');
      expect(m.at(0.24).$2, 1, reason: 'down 1');
      expect(m.at(0.35), (0, 0));
      expect(NudgeMotion.wobble(scale: 2).at(0.09).$2, 6);
      expect(NudgeMotion.wobble(scale: 1.5).at(0.09).$2, 5, reason: '4.5 rounds');
    });

    test('shove: 8 px the way Mochi faces over 200 ms, held to 1.4 s, back by 1.6 s', () {
      final right = NudgeMotion.shove(), left = NudgeMotion.shove(facing: -1);
      expect(right.at(0.2), (8, 0));
      expect(right.at(0.8), (8, 0));
      expect(right.at(1.4), (8, 0));
      expect(left.at(0.8), (-8, 0));
      expect(right.at(1.0).$2, 0);
      expect(right.at(1.6), (0, 0));
      expect(NudgeMotion.shove(scale: 2).at(0.8), (16, 0));
    });

    test('tug: ±6 px, three swings in 450 ms, home at the end', () {
      final m = NudgeMotion.tug();
      final xs = [for (var t = 0.0; t < 0.45; t += 0.005) m.at(t).$1];
      expect(xs.every((v) => v.abs() <= 6), isTrue);
      expect(xs.contains(6) && xs.contains(-6), isTrue);
      var swings = 0;
      for (var i = 1; i < xs.length; i++) {
        if (xs[i - 1] <= 0 && xs[i] > 0) swings++;
      }
      expect(swings, 3, reason: 'three swings');
      expect(m.at(0.45), (0, 0));
    });
  });

  group('every motion ends exactly at home', () {
    for (final kind in NudgeKind.values) {
      nudgeTest(kind.name, (tester) async {
        expect(nudger.start(11, kind, scale: 1), isTrue);
        var away = false;
        for (var i = 0; i < 80; i++) {
          await tester.pump(const Duration(milliseconds: 33));
          if (mover.windows[11]!.rect != home) away = true;
        }
        expect(away, isTrue, reason: 'it moved the window');
        expect(nudger.running, isFalse);
        expect(mover.windows[11]!.rect, home);
        expect(mover.moves.last, (11, home.left, home.top), reason: 'the last step is a move to exactly home');
        expect(mover.windows[11]!.rect.sameSize(home), isTrue, reason: 'never resized');
        expect(mover.attempts.every((a) => a.$1 == 11), isTrue, reason: 'only that window');
        expect(store.json, isNull, reason: 'the journal is deleted');
        expect(log, ['nudge: ${kind.name}, home ok']);
      });
    }

    nudgeTest('on a scaled display the steps are in physical pixels and still end home', (tester) async {
      expect(nudger.start(11, NudgeKind.shove, scale: 1.5, facing: -1), isTrue);
      await run(tester, 0.6);
      expect(mover.windows[11]!.rect.left, home.left - 12);
      await run(tester, 1.4);
      expect(mover.windows[11]!.rect, home);
    });
  });

  group('the foreground window', () {
    nudgeTest('is never moved: a nudge on it does not even start', (tester) async {
      mover.foregroundHwnd = 11;
      expect(nudger.start(11, NudgeKind.wobble), isFalse);
      await run(tester, 1);
      expect(mover.attempts, isEmpty);
      expect(nudger.qualify(11), NudgeSkip.foreground);
    });

    nudgeTest('becoming the foreground mid-nudge sends it home at once with one move, and ends the nudge', (tester) async {
      await away(tester);
      final before = mover.moves.length;
      mover.foregroundHwnd = 11;
      await tester.pump(const Duration(milliseconds: 33));
      expect(mover.moves.length, before + 1, reason: 'one move');
      expect(mover.moves.last, (11, home.left, home.top));
      expect(mover.windows[11]!.rect, home);
      await run(tester, 0.3);
      expect(mover.moves.length, before + 1, reason: 'and no more');
      expect(nudger.running, isFalse);
      expect(store.json, isNull);
    });
  });

  group('somebody else moves the window', () {
    nudgeTest('a user move mid-nudge stops it at once: nothing put back, nothing touched again', (tester) async {
      await away(tester);
      final moves = mover.moves.length;
      final dragged = mover.windows[11]!.rect.shifted(40, 25);
      mover.windows[11]!.rect = dragged;
      await run(tester, 2);
      expect(mover.moves.length, moves, reason: 'not one more call');
      expect(mover.windows[11]!.rect, dragged, reason: 'the user’s move wins');
      expect(nudger.running, isFalse);
      expect(store.json, isNull);
      expect(log.last, 'nudge: shove, left (moved by you)');
    });

    nudgeTest('a resize mid-nudge stops it too (same top left, other size)', (tester) async {
      await away(tester);
      final moves = mover.moves.length;
      final r = mover.windows[11]!.rect;
      final resized = PixelRect(r.left, r.top, r.right + 80, r.bottom);
      mover.windows[11]!.rect = resized;
      await run(tester, 2);
      expect(mover.moves.length, moves);
      expect(mover.windows[11]!.rect, resized);
      expect(log.last, 'nudge: shove, left (moved by you)');
    });

    nudgeTest('moved before the first step: nothing moves at all', (tester) async {
      expect(nudger.start(11, NudgeKind.tug), isTrue);
      expect(nudger.running, isTrue);
      mover.windows[11]!.rect = home.shifted(5, 5);
      await run(tester, 1);
      expect(mover.moves, isEmpty);
      expect(nudger.running, isFalse);
    });

    nudgeTest('a window lagging behind its own async moves is waited for, not taken for your doing', (tester) async {
      mover.deferred = true;
      Future<void> frame({bool land = true}) async {
        await tester.pump(const Duration(milliseconds: 33));
        if (land) mover.land();
      }

      expect(nudger.start(11, NudgeKind.tug), isTrue);
      // Two and three steps behind (still under the lag limit): it waits.
      for (var i = 0; i < 4; i++) {
        await frame(land: false);
      }
      expect(nudger.running, isTrue, reason: 'still behind its own moves, under the lag limit');
      expect(log, isEmpty);
      mover.land();
      for (var i = 0; i < 20; i++) {
        await frame();
      }
      expect(nudger.running, isFalse);
      expect(mover.windows[11]!.rect, home);
      expect(log.last, 'nudge: tug, home ok');
    });

    nudgeTest('a window that lags too long is sent home, last in its queue, and ends at home', (tester) async {
      mover.deferred = true;
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      await tester.pump(const Duration(milliseconds: 33));
      // A shove step went out; the window doesn't apply anything for longer than the lag limit.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(nudger.phase, NudgePhase.verifying, reason: 'past the lag limit: home now');
      expect(mover.attempts.last, (11, home.left, home.top), reason: 'home is the last move queued');
      mover.land();
      await tester.pump(const Duration(milliseconds: 150));
      expect(nudger.running, isFalse);
      expect(mover.windows[11]!.rect, home);
      expect(log.last, 'nudge: shove, home ok');
      expect(store.json, isNull);
    });

    nudgeTest('aborted while it still reads home but a move is on its way: a home move goes last', (tester) async {
      mover.deferred = true;
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      await tester.pump(const Duration(milliseconds: 66));
      expect(mover.windows[11]!.rect, home, reason: 'nothing has landed yet');
      expect(mover.pending, isNotEmpty);
      mover.mouse = true;
      await tester.pump(const Duration(milliseconds: 33));
      expect(mover.attempts.last, (11, home.left, home.top));
      mover.land();
      mover.mouse = false;
      await tester.pump(const Duration(milliseconds: 150));
      expect(mover.windows[11]!.rect, home, reason: 'the late shove landed, then home');
      expect(nudger.running, isFalse);
    });

    nudgeTest('a position the nudge never sent is your doing: left there', (tester) async {
      await away(tester, kind: NudgeKind.shove);
      mover.windows[11]!.rect = home.shifted(37, 21);
      await tester.pump(const Duration(milliseconds: 33));
      expect(nudger.running, isFalse);
      expect(mover.windows[11]!.rect, home.shifted(37, 21));
      expect(log.last, 'nudge: shove, left (moved by you)');
    });
  });

  group('SetWindowPos refusing', () {
    nudgeTest('the window never moved: no put-back, and that window is skipped from then on', (tester) async {
      mover.refuse.add(11);
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      await run(tester, 0.3);
      expect(nudger.running, isFalse);
      expect(mover.moves, isEmpty);
      expect(mover.attempts.length, 1, reason: 'one refused call and no put-back');
      expect(nudger.wontMove, {11});
      expect(log, ['nudge: shove, failed']);
      expect(store.json, isNull);
      mover.refuse.clear();
      expect(nudger.qualify(11), NudgeSkip.wontMove);
      expect(nudger.start(11, NudgeKind.wobble), isFalse, reason: 'skipped later');
      expect(nudger.start(12, NudgeKind.wobble), isTrue, reason: 'others still go');
    });

    nudgeTest('refusing after it had moved: one try at putting it back', (tester) async {
      mover.succeedFor = 2;
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      await run(tester, 0.4);
      expect(nudger.running, isFalse);
      expect(nudger.wontMove, {11});
      expect(log.last, 'nudge: shove, failed');
      expect(mover.attempts.last, (11, home.left, home.top), reason: 'tried home once');
    });
  });

  group('every abort goes home', () {
    Future<void> expectHome(WidgetTester tester, int before) async {
      expect(mover.windows[11]!.rect, home);
      expect(mover.moves.length, before + 1, reason: 'one move home');
      expect(nudger.running, isFalse);
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.json, isNull);
    }

    nudgeTest('a mouse button goes down', (tester) async {
      await away(tester);
      final n = mover.moves.length;
      mover.mouse = true;
      await tester.pump(const Duration(milliseconds: 33));
      await tester.pump(const Duration(milliseconds: 150));
      await expectHome(tester, n);
    });

    nudgeTest('the gate closes', (tester) async {
      await away(tester);
      final n = mover.moves.length;
      allowed = false;
      await tester.pump(const Duration(milliseconds: 33));
      await tester.pump(const Duration(milliseconds: 150));
      await expectHome(tester, n);
    });

    nudgeTest('the extra or Mischief is turned off (the gate tells recheck)', (tester) async {
      await away(tester);
      final n = mover.moves.length;
      allowed = false;
      nudger.recheck();
      await tester.pump(const Duration(milliseconds: 150));
      await expectHome(tester, n);
    });

    nudgeTest('the adventure ends or is sent home (abort)', (tester) async {
      await away(tester);
      final n = mover.moves.length;
      nudger.abort();
      await tester.pump(const Duration(milliseconds: 150));
      await expectHome(tester, n);
    });

    nudgeTest('quitting or the session ending (putBack): home before it returns', (tester) async {
      await away(tester);
      final n = mover.moves.length;
      nudger.putBack();
      expect(mover.windows[11]!.rect, home, reason: 'at once, not after a timer');
      expect(mover.moves.length, n + 1);
      expect(nudger.running, isFalse);
      expect(store.json, isNull);
    });

    nudgeTest('quitting with a move that has not landed yet keeps the journal for the next start', (tester) async {
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      await run(tester, 0.4);
      expect(mover.windows[11]!.rect, isNot(home));
      mover.deferred = true;
      nudger.putBack();
      expect(mover.pending, isNotEmpty, reason: 'the move home is on its way');
      expect(store.json, isNotNull, reason: 'not seen at home yet');
      mover.land();
      expect(mover.windows[11]!.rect, home);
      expect(nudger.recover(), isFalse, reason: 'at home already: nothing to move');
      expect(store.json, isNull);
    });

    nudgeTest('a window somebody else moved is left where they put it', (tester) async {
      await away(tester);
      final dragged = mover.windows[11]!.rect.shifted(30, 0);
      mover.windows[11]!.rect = dragged;
      final n = mover.moves.length;
      nudger.abort();
      expect(mover.moves.length, n);
      expect(mover.windows[11]!.rect, dragged);
    });
  });

  group('the read back', () {
    nudgeTest('still at the last placed position after the last step: moved home once more', (tester) async {
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      await run(tester, 0.4);
      expect(mover.windows[11]!.rect, isNot(home));
      mover.lose = true;
      nudger.abort();
      mover.lose = false;
      expect(mover.windows[11]!.rect, isNot(home), reason: 'the first home move was lost');
      await tester.pump(const Duration(milliseconds: 150));
      expect(mover.moves.where((m) => m == (11, home.left, home.top)).length, 2, reason: 'once, and once more');
      expect(mover.windows[11]!.rect, home);
      expect(log.last, 'nudge: shove, home ok');
    });

    nudgeTest('moved by somebody else meanwhile: left alone', (tester) async {
      expect(nudger.start(11, NudgeKind.wobble), isTrue);
      var elsewhere = false;
      for (var i = 0; i < 40 && !elsewhere; i++) {
        await tester.pump(const Duration(milliseconds: 33));
        if (nudger.phase == NudgePhase.verifying) {
          mover.windows[11]!.rect = home.shifted(60, 60);
          elsewhere = true;
        }
      }
      expect(elsewhere, isTrue);
      await tester.pump(const Duration(milliseconds: 150));
      expect(mover.windows[11]!.rect, home.shifted(60, 60));
      expect(log.last, 'nudge: wobble, left (moved by you)');
    });
  });

  group('the journal', () {
    nudgeTest('written before the first move, kept up before each move, deleted at the end', (tester) async {
      final seen = <Object?>[];
      mover.onMove = (hwnd, x, y) => seen.add(store.json);
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      expect(store.json, {'hwnd': 11, 'pid': 100, 'home': [400, 300], 'placed': [400, 300]}, reason: 'before the first move');
      await run(tester, 0.2);
      expect(seen, isNotEmpty);
      final first = seen.first! as Map;
      expect(first['home'], [400, 300]);
      expect(first['placed'], isNotNull, reason: 'placed is where it is about to go');
      expect(first['hwnd'], 11);
      final placed = (store.json! as Map)['placed'] as List;
      expect(placed[0], mover.windows[11]!.rect.left, reason: 'placed follows the last position set');
      await run(tester, 2);
      expect(store.json, isNull);
      expect(store.deletes, greaterThan(0));
    });

    nudgeTest('the journal of a nudge cut short is replayed: a window still at placed goes home, then the file goes', (tester) async {
      store.json = {'hwnd': 11, 'pid': 100, 'home': [400, 300], 'placed': [408, 300]};
      mover.windows[11]!.rect = home.shifted(8, 0);
      expect(nudger.recover(), isTrue);
      expect(mover.windows[11]!.rect, home);
      expect(store.json, isNull);
    });

    nudgeTest('a wrong pid (the handle was reused): untouched, file deleted', (tester) async {
      store.json = {'hwnd': 11, 'pid': 999, 'home': [400, 300], 'placed': [408, 300]};
      mover.windows[11]!.rect = home.shifted(8, 0);
      expect(nudger.recover(), isFalse);
      expect(mover.windows[11]!.rect, home.shifted(8, 0));
      expect(mover.attempts, isEmpty);
      expect(store.json, isNull);
    });

    nudgeTest('a window that is gone: nothing to move, file deleted', (tester) async {
      store.json = {'hwnd': 77, 'pid': 100, 'home': [400, 300], 'placed': [408, 300]};
      expect(nudger.recover(), isFalse);
      expect(mover.attempts, isEmpty);
      expect(store.json, isNull);
    });

    nudgeTest('a window the user moved since: left where it is, file deleted', (tester) async {
      store.json = {'hwnd': 11, 'pid': 100, 'home': [400, 300], 'placed': [408, 300]};
      mover.windows[11]!.rect = home.shifted(100, 100);
      expect(nudger.recover(), isFalse);
      expect(mover.windows[11]!.rect, home.shifted(100, 100));
      expect(store.json, isNull);
    });

    nudgeTest('an unreadable journal is deleted and moves nothing', (tester) async {
      store.json = {'hwnd': 'x'};
      expect(nudger.recover(), isFalse);
      expect(store.json, isNull);
      expect(mover.attempts, isEmpty);
    });

    nudgeTest('replayed before any new nudge', (tester) async {
      store.json = {'hwnd': 12, 'pid': 100, 'home': [1200, 200], 'placed': [1206, 200]};
      mover.windows[12]!.rect = other.shifted(6, 0);
      expect(nudger.start(11, NudgeKind.tug), isTrue);
      expect(mover.windows[12]!.rect, other, reason: 'the stranded window went home first');
    });

    nudgeTest('a nudge that ends without moving anything deletes its journal', (tester) async {
      expect(nudger.start(11, NudgeKind.wobble), isTrue);
      expect(store.json, isNotNull);
      mover.mouse = true;
      await tester.pump(const Duration(milliseconds: 33));
      expect(store.json, isNull);
      expect(mover.moves, isEmpty);
    });
  });

  group('which windows qualify', () {
    WindowInfo info({
      int hwnd = 11,
      PixelRect rect = home,
      PixelRect? frame,
      bool visible = true,
      bool iconic = false,
      bool zoomed = false,
      bool cloaked = false,
      bool ours = false,
      bool shell = false,
      bool child = false,
      bool caption = true,
      bool toolWindow = false,
      bool topmost = false,
      bool noActivate = false,
      bool owned = false,
      bool? arranged = false,
      bool hung = false,
      bool moving = false,
    }) => WindowInfo(
      hwnd: hwnd,
      rect: rect,
      frame: frame ?? rect,
      monitor: const PixelRect(0, 0, 1920, 1080),
      work: const PixelRect(0, 0, 1920, 1032),
      visible: visible,
      iconic: iconic,
      zoomed: zoomed,
      cloaked: cloaked,
      ours: ours,
      shell: shell,
      child: child,
      caption: caption,
      toolWindow: toolWindow,
      topmost: topmost,
      noActivate: noActivate,
      owned: owned,
      arranged: arranged,
      hung: hung,
      moving: moving,
    );
    NudgeSkip? why(WindowInfo? i, {int foreground = 0, bool mouse = false, Set<int> wont = const {}}) =>
        NudgeRules.why(i, foreground: foreground, mouseDown: mouse, wontMove: wont);

    test('an ordinary window qualifies', () => expect(why(info()), isNull));

    test('each rule', () {
      expect(why(null), NudgeSkip.gone);
      expect(why(info(visible: false)), NudgeSkip.hidden);
      expect(why(info(iconic: true)), NudgeSkip.minimised);
      expect(why(info(zoomed: true)), NudgeSkip.maximised);
      expect(why(info(cloaked: true)), NudgeSkip.cloaked);
      expect(why(info(ours: true)), NudgeSkip.ours);
      expect(why(info(shell: true)), NudgeSkip.shell);
      expect(why(info(child: true)), NudgeSkip.child);
      expect(why(info(caption: false)), NudgeSkip.noCaption);
      expect(why(info(toolWindow: true)), NudgeSkip.toolWindow);
      expect(why(info(topmost: true)), NudgeSkip.topmost);
      expect(why(info(noActivate: true)), NudgeSkip.noActivate);
      expect(why(info(owned: true)), NudgeSkip.owned, reason: 'dialogs have an owner');
      expect(why(info(arranged: true)), NudgeSkip.arranged);
      expect(why(info(hung: true)), NudgeSkip.hung);
      expect(why(info(moving: true)), NudgeSkip.moving);
      expect(why(info(), mouse: true), NudgeSkip.mouse);
      expect(why(info(), foreground: 11), NudgeSkip.foreground);
      expect(why(info(), wont: {11}), NudgeSkip.wontMove);
      expect(why(info(), foreground: 12, wont: {13}), isNull, reason: 'other windows do not matter');
    });

    test('without IsWindowArranged a window as tall as the work area counts as snapped (within 2 px)', () {
      expect(why(info(arranged: null, frame: const PixelRect(0, 0, 960, 1032))), NudgeSkip.fullHeight);
      expect(why(info(arranged: null, frame: const PixelRect(0, 2, 960, 1030))), NudgeSkip.fullHeight);
      expect(why(info(arranged: null, frame: const PixelRect(0, 3, 960, 1032))), isNull);
      expect(why(info(arranged: null, frame: const PixelRect(0, 0, 960, 1029))), isNull);
      expect(why(info(arranged: false, frame: const PixelRect(0, 0, 960, 1032))), isNull, reason: 'where Windows says it is not snapped');
    });

    test('a window covering its monitor is full-screen-sized', () {
      expect(why(info(frame: const PixelRect(0, 0, 1920, 1080))), NudgeSkip.fullScreen);
      expect(why(info(frame: const PixelRect(-8, -8, 1928, 1088))), NudgeSkip.fullScreen);
      expect(why(info(frame: const PixelRect(0, 0, 1920, 1079))), isNull);
    });

    nudgeTest('start asks the rules at the moment it starts, through the mover', (tester) async {
      mover.windows[11]!.toolWindow = true;
      expect(nudger.start(11, NudgeKind.wobble), isFalse);
      mover.windows[11]!.toolWindow = false;
      mover.windows[11]!.arranged = true;
      expect(nudger.start(11, NudgeKind.wobble), isFalse);
      mover.windows[11]!.arranged = false;
      mover.mouse = true;
      expect(nudger.start(11, NudgeKind.wobble), isFalse);
      mover.mouse = false;
      expect(nudger.start(404, NudgeKind.wobble), isFalse, reason: 'not a window');
      expect(mover.attempts, isEmpty);
      expect(nudger.start(11, NudgeKind.wobble), isTrue);
    });
  });

  group('one at a time', () {
    nudgeTest('a new nudge never starts while one runs (the read back included)', (tester) async {
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      expect(nudger.start(12, NudgeKind.wobble), isFalse);
      await run(tester, 1.7);
      expect(nudger.phase, anyOf(NudgePhase.verifying, NudgePhase.idle));
      if (nudger.running) expect(nudger.start(12, NudgeKind.wobble), isFalse);
      await run(tester, 0.3);
      expect(nudger.running, isFalse);
      expect(nudger.start(12, NudgeKind.wobble), isTrue);
      expect(nudger.started, 2);
    });

    nudgeTest('only while the extra may run', (tester) async {
      allowed = false;
      expect(nudger.start(11, NudgeKind.wobble), isFalse);
      expect(mover.attempts, isEmpty);
    });

    nudgeTest('at most 30 steps a second, and none once it is over', (tester) async {
      expect(nudger.start(11, NudgeKind.shove), isTrue);
      await run(tester, 2);
      final moves = mover.moves.length;
      expect(moves, lessThanOrEqualTo(30 * 2));
      await run(tester, 2);
      expect(mover.moves.length, moves);
    });
  });

  group('the Window nudges switch', () {
    test('off by default even with Mischief on; every other extra still on', () {
      const settings = MischiefSettings(enabled: true);
      expect(settings.on(MischiefExtra.windowNudges), isFalse);
      expect(settings.allows(MischiefExtra.windowNudges), isFalse);
      for (final extra in MischiefExtra.values.where((e) => e != MischiefExtra.windowNudges)) {
        expect(settings.on(extra), isTrue, reason: extra.name);
        expect(extra.defaultOn, isTrue);
      }
      expect(MischiefExtra.windowNudges.defaultOn, isFalse);
      expect(MischiefExtra.windowNudges.title, 'Window nudges');
      expect(MischiefExtra.windowNudges.moves, isTrue, reason: 'it pauses with animation effects off');
      expect(
        MischiefExtra.windowNudges.detail,
        'Mochi gives a window a tiny nudge now and then, makes the one it lands on wobble, and tugs your terminal when Claude needs you. '
        'Every window goes back exactly where it was. Never the window you’re using.',
      );
      expect(settings.withExtra(MischiefExtra.windowNudges, true).allows(MischiefExtra.windowNudges), isTrue);
    });

    test('existing settings files keep their meaning: a missing key is that extra’s default', () {
      final old = MischiefSettings.fromJson({'enabled': true, 'cursorBuddy': false, 'reacts': true});
      expect(old.on(MischiefExtra.cursorBuddy), isFalse);
      expect(old.on(MischiefExtra.celebrations), isTrue);
      expect(old.on(MischiefExtra.windowNudges), isFalse);
      expect(MischiefSettings.fromJson({'enabled': true, 'windowNudges': true}).on(MischiefExtra.windowNudges), isTrue);
      final again = MischiefSettings.fromJson(old.toJson());
      expect(again, old);
      expect(old.toJson()['windowNudges'], isFalse);
      final document = MemorySettingsDocument({'mischief': {'enabled': true}});
      expect(DesktopSettings(document).mischief.on(MischiefExtra.windowNudges), isFalse);
    });

    nudgeTest('the gate says the extra is off until it is turned on, then follows the usual rules', (tester) async {
      final t = TestDesktop.make();
      t.desktop.mischief.start();
      t.desktop.settings.mischief = const MischiefSettings(enabled: true);
      expect(t.desktop.mischief.why(MischiefExtra.windowNudges), MischiefPause.extraOff);
      expect(t.desktop.mischief.why(MischiefExtra.reacts), isNull);
      t.desktop.settings.mischief = t.desktop.settings.mischief.withExtra(MischiefExtra.windowNudges, true);
      expect(t.desktop.mischief.may(MischiefExtra.windowNudges), isTrue);
      t.desktop.motion.value = true;
      expect(t.desktop.mischief.why(MischiefExtra.windowNudges), MischiefPause.calm, reason: 'animation effects off');
      t.desktop.mischief.stop();
      await t.dispose();
    });
  });

  test('the development switch names its three motions', () {
    expect(NudgeForce.from('wobble'), NudgeForce.wobble);
    expect(NudgeForce.from(' Shove '), NudgeForce.shove);
    expect(NudgeForce.from('TUG'), NudgeForce.tug);
    expect(NudgeForce.from('dance'), isNull);
    expect(NudgeForce.from(null), isNull);
  });

  test('the process names the tug looks for are X7’s editors and terminals', () {
    expect(const NoWindowMover().processName(1), isNull);
    expect(const NoWindowMover().info(1), isNull);
    expect(const NoWindowMover().move(1, 0, 0), isFalse);
  });

}
