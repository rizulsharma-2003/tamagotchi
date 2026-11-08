// Desktop icon play (docs/SPRINT_2.md X5): the rules for which icon and where it is kicked, the put-back contract (home and
// placed, a read before every step, read back after each move, the ending, every abort path, the journal and its replay) and
// what Mochi does on the icon. Over a fake desktop; the stage is in icon_play_stage_test.dart.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/core/icon_play.dart';
import 'package:mochi_desktop/src/core/json_store.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/platform/desktop_icons.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart' show PixelRect;

import 'support/fake_icons.dart';

void main() {
  const screen = PixelRect(0, 0, 1920, 1032);

  late FakeIcons icons;
  late MemoryJsonStore store;
  late List<String> log;
  late bool allowed;
  late IconNudger nudger;

  setUp(() {
    // a, b side by side, c under a; cells 75 x 100, pictures 48 square.
    icons = FakeIcons({'a': (100, 100), 'b': (250, 100), 'c': (100, 200)});
    store = MemoryJsonStore();
    log = [];
    allowed = true;
    nudger = IconNudger(icons: icons, store: store, allowed: () => allowed, log: log.add);
  });

  Future<IconsRead> read() async => (await icons.read())!;

  (int, int)? Function(IconsRead, DesktopIcon) toward(double facing, {List<PixelRect> windows = const []}) =>
      (read, icon) => IconRules.kickTarget(read, icon, facing: facing, screen: screen, windows: windows);

  Future<DesktopIcon> pick(String id) async => (await read()).find(id)!;

  Future<bool> begin(String id) async => nudger.begin(await pick(id));

  group('the extra', () {
    test('Desktop icons: off by default even with Mischief on, paused like the moving extras, and says what it does', () {
      const settings = MischiefSettings(enabled: true);
      expect(settings.on(MischiefExtra.desktopIcons), isFalse);
      expect(settings.allows(MischiefExtra.desktopIcons), isFalse);
      expect(MischiefExtra.desktopIcons.defaultOn, isFalse);
      expect(MischiefExtra.desktopIcons.moves, isTrue);
      expect(MischiefExtra.desktopIcons.title, 'Desktop icons');
      expect(
        MischiefExtra.desktopIcons.detail,
        'On its adventures, Mochi sits on a desktop icon, kicks it over a little and puts it back exactly where it was. Not with Auto arrange on.',
      );
      expect(MischiefSettings.fromJson({'enabled': true, 'desktopIcons': true}).on(MischiefExtra.desktopIcons), isTrue);
      expect(MischiefSettings.fromJson({'enabled': true}).on(MischiefExtra.desktopIcons), isFalse, reason: 'an older settings file keeps its meaning');
    });

    test('the development switch: MOCHI_DESKTOP_ICONS=visit', () {
      expect(IconForce.from('visit'), IconForce.visit);
      expect(IconForce.from(' Visit '), IconForce.visit);
      expect(IconForce.from('x'), isNull);
      expect(IconForce.from(null), isNull);
    });
  });

  group('which icon', () {
    Future<IconSkip?> why(String id, {List<PixelRect> windows = const [], PixelRect area = screen}) async {
      final r = await read();
      return IconRules.why(r, r.find(id)!, display: area, windows: windows);
    }

    test('an icon in view is fine; hidden icons, Auto arrange and an unknown desktop are skipped', () async {
      expect(await why('a'), isNull);
      icons.hidden = true;
      expect(await why('a'), IconSkip.hidden);
      icons.hidden = false;
      icons.autoArrange = true;
      expect(await why('a'), IconSkip.autoArrange);
      icons.autoArrange = false;
      icons.more = true;
      expect(await why('a'), IconSkip.unknown, reason: 'more icons than were listed: nothing is safe to call free');
    });

    test('a picture a window covers is skipped (the picture: the cell centred, the icon size square, at the cell’s top)', () async {
      final r = await read();
      expect(IconRules.image(r, r.find('a')!), const PixelRect(113, 100, 161, 148));
      expect(await why('a', windows: [const PixelRect(150, 140, 400, 400)]), IconSkip.covered, reason: 'overlaps the picture’s corner');
      expect(await why('a', windows: [const PixelRect(161, 100, 400, 400)]), isNull, reason: 'touches its edge only');
      expect(await why('a', windows: [const PixelRect(100, 150, 400, 400)]), isNull, reason: 'covers the label below the picture, not the picture');
    });

    test('an icon off the outing’s display is skipped', () async {
      expect(await why('a', area: const PixelRect(1920, 0, 4480, 1440)), IconSkip.offDisplay);
      expect(await why('a', area: const PixelRect(0, 0, 1920, 120)), IconSkip.offDisplay, reason: 'its picture would stick out of the work area');
    });

    test('the nearest qualifying icon comes first, and the runner’s answer is checked', () async {
      final r = await read();
      final list = IconRules.candidates(r, display: screen, windows: [const PixelRect(240, 90, 340, 160)], x: 300, y: 130);
      expect([for (final i in list) i.id], ['a', 'c'], reason: 'b is covered; a is nearer than c');
      expect(IconsRead.fromJson({'autoArrange': false, 'grid': true, 'hidden': false, 'iconSize': 48, 'spacing': [75, 100], 'icons': []}), isNotNull);
      expect(IconsRead.fromJson({'iconSize': 48, 'spacing': [0, 100], 'icons': []}), isNull);
      expect(IconsRead.fromJson({'iconSize': 48, 'spacing': [75, 100], 'icons': [{'id': 'x', 'x': 1}]}), isNull);
      final dup = IconsRead.fromJson({'iconSize': 48, 'spacing': [75, 100], 'icons': [{'id': 'x', 'x': 1, 'y': 2}, {'id': 'x', 'x': 3, 'y': 4}]})!;
      expect(dup.more, isTrue);
      final many = IconsRead.fromJson({'iconSize': 48, 'spacing': [75, 100], 'icons': [for (var i = 0; i < 70; i++) {'id': 'i$i', 'x': i, 'y': i}]})!;
      expect(many.icons.length, 64);
      expect(many.more, isTrue);
    });
  });

  group('where it is kicked', () {
    Future<(int, int)?> target(String id, double facing, {List<PixelRect> windows = const []}) async {
      final r = await read();
      return IconRules.kickTarget(r, r.find(id)!, facing: facing, screen: screen, windows: windows);
    }

    test('grid on: one cell the way Mochi faces, into a free cell', () async {
      expect(await target('a', 1), (175, 100));
      expect(await target('a', -1), (25, 100));
    });

    test('grid on: an occupied cell sends it the other way; both occupied is none free', () async {
      // b sits a whole cell to the right of a's right neighbour... put one in the right cell.
      icons.positions['r'] = (175, 100);
      expect(await target('a', 1), (25, 100), reason: 'the right cell is taken');
      icons.positions['l'] = (25, 100);
      expect(await target('a', 1), isNull);
      expect(await target('a', -1), isNull);
    });

    test('grid on: free means nobody within half a cell of it', () async {
      icons.positions['r'] = (175 + 37, 100 + 49);
      expect(await target('a', 1), (25, 100), reason: 'under half a cell away both ways: taken');
      icons.positions['r'] = (175 + 38, 100);
      expect(await target('a', 1), (175, 100), reason: 'half a cell or more away: free');
      icons.positions['r'] = (175, 100 + 50);
      expect(await target('a', 1), (175, 100));
    });

    test('grid on: a cell off the screen is no cell (both edges)', () async {
      icons.positions['edge'] = (0, 300);
      expect(await target('edge', -1), (75, 300), reason: 'left of x=0 is off screen: the other way');
      icons.positions['right'] = (1845, 300);
      expect(await target('right', 1), (1770, 300), reason: 'a cell right of 1920 is off screen');
      icons.positions['corner'] = (0, 0);
      expect(await target('corner', -1), (75, 0));
      icons.positions['wide'] = (1845, 0);
      expect(await target('wide', 1), (1770, 0));
      final tiny = IconRules.kickTarget(await read(), (await read()).find('a')!, facing: 1, screen: const PixelRect(100, 100, 175, 200));
      expect(tiny, isNull, reason: 'a screen one cell wide has nowhere to go');
    });

    test('grid on: nothing is kicked to where a window hides it', () async {
      expect(await target('a', 1, windows: [const PixelRect(170, 90, 300, 160)]), (25, 100));
    });

    test('grid off: a third of a cell sideways, not touching another icon', () async {
      icons.grid = false;
      expect(await target('a', 1), (125, 100), reason: '75 / 3 = 25 px');
      expect(await target('a', -1), (75, 100));
      // b is 150 px right of a: a picture 25 px nearer still leaves a gap. One right next to it does not.
      icons.positions['r'] = (160, 100);
      expect(await target('a', 1), (75, 100), reason: 'the picture would overlap that neighbour');
      icons.positions['l'] = (50, 100);
      expect(await target('a', 1), isNull);
    });

    test('not with Auto arrange or hidden icons', () async {
      icons.autoArrange = true;
      expect(await target('a', 1), isNull);
      icons.autoArrange = false;
      icons.hidden = true;
      expect(await target('a', 1), isNull);
    });
  });

  group('the visit’s steps', () {
    test('kick, read back, push home: it ends at exactly home, and the journal goes', () async {
      expect(await begin('a'), isTrue);
      expect(nudger.active, isTrue);
      expect(nudger.home, (100, 100));
      expect(store.json, isNull, reason: 'nothing has moved yet: no journal');
      expect(await nudger.kick(toward(1)), IconStep.moved);
      expect(icons.positions['a'], (175, 100));
      expect(nudger.placed, (175, 100));
      expect(nudger.displaced, isTrue);
      expect(store.json, {'id': 'a', 'home': [100, 100], 'placed': [175, 100]});
      await nudger.pushHome();
      expect(icons.positions['a'], (100, 100));
      expect(nudger.active, isFalse);
      expect(store.json, isNull);
      expect(log, ['icons: kicked, home ok']);
      expect(icons.movesOf('a'), [(175, 100), (100, 100)]);
      expect(icons.positions['b'], (250, 100), reason: 'nobody else was touched');
      expect(icons.positions['c'], (100, 200));
    });

    test('the journal is written before the first move and before each one, and says where the icon may be', () async {
      final seen = <Object?>[];
      icons.onMove = (id, x, y) => seen.add(store.json);
      await begin('a');
      await nudger.kick(toward(1));
      expect(seen.single, {'id': 'a', 'home': [100, 100], 'placed': [175, 100], 'was': [100, 100]}, reason: 'written first: it may be at either');
      expect(store.json, {'id': 'a', 'home': [100, 100], 'placed': [175, 100]}, reason: 'then settled on where it was read');
      await nudger.pushHome();
      expect(seen.length, 2);
      expect(seen.last, {'id': 'a', 'home': [100, 100], 'placed': [175, 100]}, reason: 'the way home keeps the journal on the kicked place until home is seen');
      expect(store.json, isNull);
    });

    test('every step reads the desktop first, and the move is read back', () async {
      await begin('a');
      final before = icons.reads;
      await nudger.kick(toward(1));
      expect(icons.reads - before, 2, reason: 'a read, the move, a read back');
      final mid = icons.reads;
      await nudger.pushHome();
      expect(icons.reads - mid, 2, reason: 'a read, the move home, a read');
      final idle = icons.reads;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(icons.reads, idle, reason: 'nothing polls');
    });

    test('Explorer snaps it to another cell: placed is where it really is, and home is still exact', () async {
      icons.snap = (id, x, y) => (x + 5, y - 3);
      await begin('a');
      expect(await nudger.kick(toward(1)), IconStep.moved);
      expect(nudger.placed, (180, 97));
      expect(store.json, {'id': 'a', 'home': [100, 100], 'placed': [180, 97]});
      icons.snap = null;
      await nudger.pushHome();
      expect(icons.positions['a'], (100, 100));
      expect(log, ['icons: kicked, home ok']);
    });

    test('a user move before the first kick: nothing is moved and nothing put back', () async {
      await begin('a');
      icons.positions['a'] = (400, 400);
      expect(await nudger.kick(toward(1)), IconStep.ended);
      expect(icons.moves, isEmpty);
      expect(icons.positions['a'], (400, 400));
      expect(log, ['icons: left (moved)']);
      expect(nudger.active, isFalse);
    });

    test('a user move mid-visit: the icon is where they put it, and is never touched again', () async {
      await begin('a');
      await nudger.kick(toward(1));
      icons.positions['a'] = (600, 500);
      await nudger.pushHome();
      expect(icons.positions['a'], (600, 500));
      expect(icons.movesOf('a'), [(175, 100)], reason: 'only the kick: no put-back');
      expect(log, ['icons: left (moved)']);
      expect(store.json, isNull);
      expect(nudger.active, isFalse);
    });

    test('Explorer rearranging it mid-visit (back onto home on its own) is not touched either', () async {
      await begin('a');
      await nudger.kick(toward(1));
      icons.positions['a'] = (100, 100);
      await nudger.pushHome();
      expect(icons.movesOf('a'), [(175, 100)]);
      expect(log, ['icons: kicked, home ok']);
    });

    test('an icon that is gone: nothing is moved', () async {
      await begin('a');
      icons.positions.remove('a');
      expect(await nudger.kick(toward(1)), IconStep.ended);
      expect(icons.moves, isEmpty);
      await begin('b');
      await nudger.kick(toward(1));
      icons.positions.remove('b');
      await nudger.pushHome();
      expect(icons.movesOf('b'), [(325, 100)], reason: 'the kick only');
      expect(log, ['icons: left (moved)', 'icons: left (moved)']);
      expect(store.json, isNull);
    });

    test('a failed move: the icon did not move, so there is nothing to put back', () async {
      icons.refuse.add('a');
      await begin('a');
      expect(await nudger.kick(toward(1)), IconStep.ended);
      expect(icons.positions['a'], (100, 100));
      expect(log, ['icons: not moved']);
      expect(store.json, isNull);
      expect(nudger.active, isFalse);
    });

    test('a move the shell said yes to but never made ends the same way', () async {
      icons.ignoreAll = true;
      await begin('a');
      expect(await nudger.kick(toward(1)), IconStep.ended);
      expect(log, ['icons: not moved']);
      expect(icons.moves.length, 1);
    });

    test('the home move is tried once more if the icon is still where it was put; then it is left, and the journal stays', () async {
      await begin('a');
      await nudger.kick(toward(1));
      icons.ignoreNext = 1;
      await nudger.pushHome();
      expect(icons.positions['a'], (100, 100));
      expect(icons.movesOf('a'), [(175, 100), (100, 100), (100, 100)], reason: 'home, then once more');
      expect(log, ['icons: kicked, home ok']);

      await begin('b');
      await nudger.kick(toward(1));
      icons.refuse.add('b');
      await nudger.pushHome();
      expect(icons.positions['b'], (325, 100));
      expect(icons.movesOf('b'), [(325, 100), (250, 100), (250, 100)], reason: 'exactly two tries');
      expect(log.last, 'icons: failed');
      expect(store.json, {'id': 'b', 'home': [250, 100], 'placed': [325, 100]}, reason: 'the next start tries again');
      expect(nudger.active, isFalse);
    });

    test('a home move that lands somewhere else is left there', () async {
      await begin('a');
      await nudger.kick(toward(1));
      icons.snap = (id, x, y) => (x + 7, y);
      await nudger.pushHome();
      expect(icons.movesOf('a'), [(175, 100), (100, 100)]);
      expect(log, ['icons: left (moved)']);
      expect(store.json, isNull);
    });

    test('Auto arrange coming on mid-visit stops it', () async {
      await begin('a');
      await nudger.kick(toward(1));
      icons.autoArrange = true;
      await nudger.pushHome();
      expect(icons.movesOf('a'), [(175, 100)]);
      expect(log, ['icons: auto-arrange']);
    });

    test('no target (none free) ends the visit with nothing moved; a second kick after a move goes home', () async {
      await begin('a');
      expect(await nudger.kick((read, icon) => null), IconStep.ended);
      expect(icons.moves, isEmpty);
      expect(log, ['icons: none free']);

      await begin('b');
      await nudger.kick(toward(1));
      expect(await nudger.kick((read, icon) => null), IconStep.ended);
      expect(icons.positions['b'], (250, 100), reason: 'it goes home');
      expect(log.last, 'icons: kicked, home ok');
    });

    test('a read that fails: nothing is touched; with the icon away the journal stays', () async {
      await begin('a');
      icons.failReads = true;
      expect(await nudger.kick(toward(1)), IconStep.ended);
      expect(icons.moves, isEmpty);
      expect(log, ['icons: failed']);

      icons.failReads = false;
      await begin('a');
      await nudger.kick(toward(1));
      icons.failReads = true;
      await nudger.pushHome();
      expect(icons.movesOf('a'), [(175, 100)]);
      expect(store.json, isNotNull, reason: 'it may still be away from home');
    });

    test('one visit at a time, and not while the extra may not run', () async {
      expect(await begin('a'), isTrue);
      expect(await begin('b'), isFalse);
      nudger.abort();
      await Future<void>.delayed(Duration.zero);
      allowed = false;
      expect(await begin('b'), isFalse);
      expect(icons.moves, isEmpty);
    });
  });

  group('every abort path goes home at once', () {
    Future<void> kicked() async {
      await begin('a');
      await nudger.kick(toward(1));
      expect(icons.positions['a'], (175, 100));
    }

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

    test('abort() (the adventure ended, Mochi sent home): one move home, if it is still at placed', () async {
      await kicked();
      nudger.abort();
      await settle();
      expect(icons.positions['a'], (100, 100));
      expect(nudger.active, isFalse);
      expect(store.json, isNull);
      expect(log, ['icons: kicked, home ok']);
    });

    test('abort() before anything moved: nothing is touched', () async {
      await begin('a');
      nudger.abort();
      await settle();
      expect(icons.moves, isEmpty);
      expect(log, ['icons: not moved']);
      expect(nudger.active, isFalse);
    });

    test('abort() while the icon is not at placed: it is left alone', () async {
      await kicked();
      icons.positions['a'] = (900, 900);
      nudger.abort();
      await settle();
      expect(icons.positions['a'], (900, 900));
      expect(icons.movesOf('a'), [(175, 100)]);
    });

    test('abort() during a step in flight: that step makes no move, and home goes after it', () async {
      await begin('a');
      final hold = Completer<void>();
      icons.hold = hold;
      final kick = nudger.kick(toward(1));
      await Future<void>.delayed(Duration.zero);
      nudger.abort();
      hold.complete();
      expect(await kick, IconStep.ended);
      await settle();
      expect(icons.moves, isEmpty, reason: 'it was read but never moved');
      expect(icons.positions['a'], (100, 100));
      expect(nudger.active, isFalse);
    });

    test('abort() while the move is on its way: it lands, then goes home', () async {
      await begin('a');
      final hold = Completer<void>();
      icons.onMove = (id, x, y) => icons.hold = hold;
      final kick = nudger.kick(toward(1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      nudger.abort();
      hold.complete();
      await kick;
      await settle();
      expect(icons.movesOf('a'), [(175, 100), (100, 100)]);
      expect(icons.positions['a'], (100, 100));
      expect(store.json, isNull);
    });

    test('a mouse button down, the desktop or a taskbar in front, or the gate closing stops the next move and sends it home', () async {
      for (final cause in ['mouse', 'desktop', 'gate']) {
        icons.positions['a'] = (100, 100);
        icons.moves.clear();
        log.clear();
        await begin('a');
        await nudger.kick(toward(1));
        expect(icons.positions['a'], (175, 100), reason: cause);
        switch (cause) {
          case 'mouse':
            icons.mouse = true;
          case 'desktop':
            icons.desktopInUse = true;
          case 'gate':
            allowed = false;
        }
        expect(nudger.blocked(), isTrue);
        // The next step: it will not move anything further, and it ends at home.
        expect(await nudger.kick(toward(1)), IconStep.ended, reason: cause);
        expect(icons.positions['a'], (100, 100), reason: cause);
        expect(icons.movesOf('a'), [(175, 100), (100, 100)], reason: cause);
        expect(log, ['icons: kicked, home ok']);
        icons.mouse = false;
        icons.desktopInUse = false;
        allowed = true;
      }
    });

    test('recheck() sends it home when the extra or Mischief goes off, and does nothing otherwise', () async {
      await kicked();
      nudger.recheck();
      await settle();
      expect(nudger.active, isTrue, reason: 'still allowed');
      allowed = false;
      nudger.recheck();
      await settle();
      expect(icons.positions['a'], (100, 100));
      expect(nudger.active, isFalse);
    });

    test('putBack() (the app quitting, Windows ending the session) goes home too', () async {
      await kicked();
      nudger.putBack();
      await settle();
      expect(icons.positions['a'], (100, 100));
      expect(store.json, isNull);
    });

    test('dispose() puts it back', () async {
      await kicked();
      nudger.dispose();
      await settle();
      expect(icons.positions['a'], (100, 100));
    });
  });

  group('the journal at launch', () {
    Future<void> write(Map<String, Object?> record) async => store.write(record);

    test('an icon still at `placed` goes home, and the file goes', () async {
      icons.positions['a'] = (175, 100);
      await write({'id': 'a', 'home': [100, 100], 'placed': [175, 100]});
      expect(await nudger.recover(), isTrue);
      expect(icons.positions['a'], (100, 100));
      expect(store.json, isNull);
      expect(log, ['icons: recovered an icon (home ok)']);
    });

    test('an icon at `was` (the move had not landed) goes home too', () async {
      icons.positions['a'] = (175, 100);
      await write({'id': 'a', 'home': [100, 100], 'placed': [250, 100], 'was': [175, 100]});
      expect(await nudger.recover(), isTrue);
      expect(icons.positions['a'], (100, 100));
    });

    test('an icon moved since is left where it is; the file goes', () async {
      icons.positions['a'] = (333, 222);
      await write({'id': 'a', 'home': [100, 100], 'placed': [175, 100]});
      expect(await nudger.recover(), isFalse);
      expect(icons.positions['a'], (333, 222));
      expect(icons.moves, isEmpty);
      expect(store.json, isNull);
    });

    test('an icon gone, or already home, is not touched; the file goes', () async {
      await write({'id': 'gone', 'home': [100, 100], 'placed': [175, 100]});
      expect(await nudger.recover(), isFalse);
      expect(store.json, isNull);
      await write({'id': 'a', 'home': [100, 100], 'placed': [175, 100]});
      expect(await nudger.recover(), isFalse);
      expect(icons.moves, isEmpty);
      expect(store.json, isNull);
    });

    test('with Auto arrange on, or a journal that makes no sense, nothing is moved; the file goes', () async {
      icons.positions['a'] = (175, 100);
      icons.autoArrange = true;
      await write({'id': 'a', 'home': [100, 100], 'placed': [175, 100]});
      expect(await nudger.recover(), isFalse);
      expect(icons.moves, isEmpty);
      expect(store.json, isNull);
      await write({'id': 'a', 'home': 'x'});
      expect(await nudger.recover(), isFalse);
      expect(store.json, isNull);
      expect(await nudger.recover(), isFalse, reason: 'no file: nothing to do');
    });

    test('a new visit replays an old journal first', () async {
      icons.positions['c'] = (175, 200);
      await write({'id': 'c', 'home': [100, 200], 'placed': [175, 200]});
      expect(await begin('a'), isTrue);
      expect(icons.positions['c'], (100, 200));
      expect(store.json, isNull);
    });
  });

  group('what Mochi does', () {
    Future<IconVisit> visit() async {
      final r = await read();
      return IconVisit(
        nudger: nudger,
        read: r,
        icon: r.find('a')!,
        from: (600, 300),
        facing: 1,
        screen: screen,
        windows: const [],
        scale: 1,
        now: 0,
        sit: 3,
      );
    }

    /// Runs the clock in 50 ms steps, letting the shell answer in between; every frame goes to [seen].
    Future<void> run(IconVisit v, double until, {double from = 0, void Function(IconFrame frame, double t)? seen}) async {
      for (var t = from; t <= until; t += 0.05) {
        final frame = v.frame(t);
        if (frame != null) seen?.call(frame, t);
        await Future<void>.delayed(Duration.zero);
        if (v.finished && frame == null) return;
      }
    }

    test('leaps to the icon’s top, sits 3 s, kicks, hops after it, sits pleased 2 s, pushes it home, hops back, done', () async {
      await begin('a');
      final v = await visit();
      final phases = <String>[];
      var last = '';
      final feet = <(int, int)>[];
      await run(
        v,
        14,
        seen: (frame, t) {
          final name = '${frame.animation.name}${frame.accent != null ? '+' : ''}';
          if (name != last) {
            phases.add(name);
            last = name;
          }
          feet.add(frame.feet);
        },
      );
      expect(v.finished, isTrue);
      expect(phases.take(3), ['excitedJump', 'sit', 'bat']);
      expect(phases, contains('sit+'), reason: 'the pleased sit');
      expect(feet.map((f) => f.$2).reduce((a, b) => a < b ? a : b), lessThan(100), reason: 'the leap arcs above the icon’s top before it lands');
      expect(IconRules.top(await read(), (await read()).find('a')!), (137, 100), reason: 'the icon’s top: its picture’s middle');
      expect(icons.positions['a'], (100, 100));
      expect(icons.movesOf('a'), [(175, 100), (100, 100)]);
      expect(log, ['icons: kicked, home ok']);
      expect(store.json, isNull);
    });

    test('it sits on the icon at its top while it waits, then on the kicked icon (feet at the middle of the picture’s top)', () async {
      await begin('a');
      final v = await visit();
      final sat = <(int, int)>[];
      await run(v, 5.5, seen: (frame, t) {
        if (frame.animation.name == 'sit') sat.add(frame.feet);
      });
      expect(sat.first, (137, 100));
      expect(sat.last, (212, 100), reason: 'the kicked icon, a cell to the right');
    });

    test('with no free place it just sits, then carries on', () async {
      icons.positions['r'] = (175, 100);
      icons.positions['l'] = (25, 100);
      await begin('a');
      final v = await visit();
      await run(v, 8);
      expect(v.finished, isTrue);
      expect(icons.moves, isEmpty);
      expect(log, ['icons: none free']);
    });

    test('a user move while it sits pleased: Mochi stays out of it and the icon is left', () async {
      await begin('a');
      final v = await visit();
      await run(v, 5, seen: (frame, t) {
        if (t > 4.8) icons.positions['a'] = (700, 700);
      });
      await run(v, 14, from: 5);
      expect(v.finished, isTrue);
      expect(icons.positions['a'], (700, 700));
      expect(icons.movesOf('a'), [(175, 100)]);
      expect(log, ['icons: left (moved)']);
    });

    test('abort() cuts it short: the icon goes home and it is done', () async {
      await begin('a');
      final v = await visit();
      await run(v, 5);
      expect(icons.positions['a'], (175, 100));
      v.abort();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(v.finished, isTrue);
      expect(v.frame(6), isNull);
      expect(icons.positions['a'], (100, 100));
    });

    test('a farther icon takes a longer leap, never more than 1.4 s', () {
      expect(IconVisit.leapSeconds((0, 0), (10, 0), 1), closeTo(0.45, 0.01));
      expect(IconVisit.leapSeconds((0, 0), (900, 0), 1), closeTo(1.05, 0.01));
      expect(IconVisit.leapSeconds((0, 0), (9000, 0), 1), 1.4);
    });
  });
}
