// Desktop icon play (docs/SPRINT_2.md X5, Mischief): on a desktop adventure Mochi may sit on one of your desktop icons, kick
// it over a little and put it back exactly where it was. It moves your own layout, which some people arrange carefully, so it
// is small, rare and always undone, and when in doubt it does not move anything. This file has no Windows in it
// ([DesktopIcons] is the adapter; platform/desktop_icons.dart is the real one, tests use a fake), and holds the put-back
// contract ([IconNudger]), the rules for which icon and where it goes ([IconRules]) and what Mochi does ([IconVisit]):
//
// - Which icon ([IconRules.why]): on the outing's display, with its picture not covered by any window of the adventure's
//   survey, on a desktop with icons shown and Auto arrange off, and the whole desktop known (at most 64 icons).
// - Where it is kicked ([IconRules.kickTarget]): with "Align to grid" on, one cell sideways (the way Mochi faces, else the
//   other way) into a cell that is on screen and free (no other icon within half a cell of it); with it off, a third of a cell
//   sideways, not touching another icon. No such place: Mochi just sits, then carries on.
// - [IconNudger] runs one visit at a time:
//   * `home` is the icon's position at the start (a fresh read), `placed` where it actually is after each move.
//   * Every shell call is answered later (the runner's worker thread), and the calls of one visit never overlap.
//   * Before every step, the last one included, the desktop is read again. If the icon is not at `placed` (somebody moved
//     it, Explorer rearranged, the icon is gone, Auto arrange came on, the icons were hidden) the visit stops and the icon is
//     never touched again.
//   * After every move it is read back: Explorer may snap it to another cell, and `placed` is wherever it actually is. A
//     first move that did not move it at all ends the visit with nothing to put back.
//   * The ending is a move to `home`, then a read; if it is not home and still at `placed`, once more; otherwise it is left.
//   * Abort paths go home at once, if the icon is still at `placed`: the desktop or a taskbar becomes the foreground, a mouse
//     button goes down, the gate closes or the extra or Mischief goes off, the adventure ends or is sent home, the app quits.
//   * The journal (`icon-nudge.json`: id, home, placed, and `was` while a move is on its way) is written before the first
//     move and updated before each one, and deleted at the end. At launch, and before any new visit, an icon with that id
//     that is at `placed` (or `was`) goes back to `home`; the file goes either way.
//   * Icon names, paths and contents are never read: an id is a hash, and nothing about an icon is logged.
// - One line per visit to the stroll-debug log: "icons: kicked, home ok | left (moved) | none free | auto-arrange | ...".

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_art/mochi_art.dart' show PetAnimation, PetEyes, PetPose;

import '../platform/desktop_icons.dart';
import '../platform/taskbar.dart' show PixelRect;
import 'json_store.dart';

/// The development switch `MOCHI_DESKTOP_ICONS=visit`: every outing visits an icon if one qualifies (the gate and the icon
/// rules still apply).
enum IconForce {
  visit;

  static IconForce? from(String? value) => (value ?? '').trim().toLowerCase() == 'visit' ? IconForce.visit : null;
}

/// Why an icon may not be visited.
enum IconSkip { autoArrange, hidden, unknown, offDisplay, covered }

abstract final class IconRules {
  /// The icon's picture: its cell's width centred, the icon size square, at the top of the cell.
  static PixelRect image(IconsRead read, DesktopIcon icon) => PixelRect.ltwh(icon.x + (read.cellWidth - read.iconSize) ~/ 2, icon.y, read.iconSize, read.iconSize);

  /// Where Mochi's feet go to sit on [icon]: the middle of the top of its picture.
  static (int, int) top(IconsRead read, DesktopIcon icon) {
    final picture = image(read, icon);
    return ((picture.left + picture.right) ~/ 2, picture.top);
  }

  /// Why [icon] may not be visited now, or null: it may. [display] is the outing's display (its work area), [windows] the
  /// frames of the windows at the adventure's last survey.
  static IconSkip? why(IconsRead read, DesktopIcon icon, {required PixelRect display, required List<PixelRect> windows}) {
    if (read.hidden) return IconSkip.hidden;
    if (read.autoArrange) return IconSkip.autoArrange;
    if (read.more || read.cellWidth <= 0 || read.cellHeight <= 0 || read.iconSize <= 0) return IconSkip.unknown;
    final picture = image(read, icon);
    if (!_inside(display, picture)) return IconSkip.offDisplay;
    if (windows.any(picture.overlaps)) return IconSkip.covered;
    return null;
  }

  /// The icons that may be visited, nearest to ([x], [y]) first.
  static List<DesktopIcon> candidates(IconsRead read, {required PixelRect display, required List<PixelRect> windows, required int x, required int y}) {
    final list = [
      for (final icon in read.icons)
        if (why(read, icon, display: display, windows: windows) == null) icon,
    ];
    double distance(DesktopIcon icon) {
      final (cx, cy) = top(read, icon);
      return math.sqrt(math.pow(cx - x, 2) + math.pow(cy - y, 2));
    }

    list.sort((a, b) => distance(a).compareTo(distance(b)));
    return list;
  }

  /// Where [icon]'s cell goes when Mochi kicks it, or null when no place qualifies. [facing] 1 is right, -1 left; [screen] is
  /// the display; [windows] the frames that cover the desktop (nothing is kicked to where a window hides it).
  static (int, int)? kickTarget(
    IconsRead read,
    DesktopIcon icon, {
    required double facing,
    required PixelRect screen,
    List<PixelRect> windows = const [],
  }) {
    if (read.hidden || read.autoArrange || read.more) return null;
    final first = facing >= 0 ? 1 : -1;
    for (final side in [first, -first]) {
      final step = read.grid ? read.cellWidth : (read.cellWidth / 3).round();
      if (step <= 0) continue;
      final at = (icon.x + side * step, icon.y);
      final cell = PixelRect.ltwh(at.$1, at.$2, read.cellWidth, read.cellHeight);
      if (!_inside(screen, cell)) continue;
      final moved = DesktopIcon(icon.id, at.$1, at.$2);
      final picture = image(read, moved);
      if (windows.any(picture.overlaps)) continue;
      var clear = true;
      for (final other in read.icons) {
        if (other.id == icon.id) continue;
        if (read.grid) {
          // Free: nobody's position within half a cell of the target.
          if ((other.x - at.$1).abs() * 2 < read.cellWidth && (other.y - at.$2).abs() * 2 < read.cellHeight) clear = false;
        } else if (image(read, other).overlaps(picture)) {
          clear = false;
        }
        if (!clear) break;
      }
      if (clear) return at;
    }
    return null;
  }

  static bool _inside(PixelRect outer, PixelRect inner) => inner.left >= outer.left && inner.top >= outer.top && inner.right <= outer.right && inner.bottom <= outer.bottom;
}

/// What a visit in flight was doing, as the journal keeps it. [was] is where the icon was before the move that [placed]
/// names, while that move may still be on its way: the icon may be at either.
@immutable
class IconRecord {
  const IconRecord({required this.id, required this.home, required this.placed, this.was});

  final String id;
  final (int, int) home;
  final (int, int) placed;
  final (int, int)? was;

  Map<String, Object?> toJson() => {
    'id': id,
    'home': [home.$1, home.$2],
    'placed': [placed.$1, placed.$2],
    if (was != null) 'was': [was!.$1, was!.$2],
  };

  static IconRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    (int, int)? point(Object? value) => value is List && value.length == 2 && value[0] is int && value[1] is int ? (value[0] as int, value[1] as int) : null;
    final id = json['id'], home = point(json['home']), placed = point(json['placed']);
    if (id is! String || id.isEmpty || home == null || placed == null) return null;
    return IconRecord(id: id, home: home, placed: placed, was: point(json['was']));
  }
}

/// How one step of a visit went.
enum IconStep {
  /// The icon moved and is at [IconNudger.placed] (read back).
  moved,

  /// The visit is over (nothing to put back, the icon is home, or it was left alone); [IconNudger.active] is false.
  ended,
}

/// One icon visit at a time, with the put-back contract above.
class IconNudger {
  IconNudger({required this.icons, required JsonStore store, required this.allowed, this.log}) : _store = store;

  final DesktopIcons icons;
  final JsonStore _store;

  /// The gate says the extra may run now.
  final bool Function() allowed;

  /// The stroll-debug log, when it is on.
  void Function(String)? log;

  String? _id;
  late (int, int) _home;
  late (int, int) _placed;

  /// The icon has been moved at least once this visit.
  bool _moved = false;
  bool _ending = false;
  Future<void> _tail = Future<void>.value();

  /// Visits begun, reads, and every move asked of the shell (tests, the perf meter).
  int begun = 0;
  int reads = 0;
  int moves = 0;

  /// The log line, and [lastResult], of a visit that kicked an icon and saw it home.
  static const String homeOk = 'kicked, home ok';

  /// How the last visit ended (the line the log got, without "icons: "); null while none has.
  String? lastResult;

  /// A visit is in progress (the icon may be away from home).
  bool get active => _id != null;

  /// The icon's home, and where it is now (null: no visit).
  (int, int)? get home => active ? _home : null;
  (int, int)? get placed => active ? _placed : null;
  String? get id => _id;

  /// The icon is away from home.
  bool get displaced => active && _moved;

  /// The desktop now (for choosing an icon).
  Future<IconsRead?> read() {
    reads++;
    return icons.read();
  }

  // ---- beginning ----

  /// Starts a visit to [icon] (from a read made just now); false when one is running or the extra may not run. Puts back an
  /// icon an earlier crash left away first.
  Future<bool> begin(DesktopIcon icon) async {
    if (active || !allowed()) return false;
    _id = icon.id;
    _home = (icon.x, icon.y);
    _placed = _home;
    _moved = false;
    _ending = false;
    begun++;
    await recover(keepVisit: true);
    if (_id == null || _ending) return false;
    if (!allowed()) {
      abort();
      return false;
    }
    return true;
  }

  // ---- stepping ----

  /// Moves the icon: reads the desktop, asks [choose] where (from that fresh read; null: nowhere qualifies, which ends the
  /// visit with nothing moved), moves it, and reads it back. Never touches an icon that is not where this visit put it.
  Future<IconStep> kick((int, int)? Function(IconsRead read, DesktopIcon icon) choose) => _enqueue(() async {
    final id = _id;
    if (id == null || _ending) return IconStep.ended;
    final read = await _look();
    if (_ending) return IconStep.ended;
    final here = _verify(read, id);
    if (here == null) return IconStep.ended;
    if (blocked()) {
      await _homeFlow(first: read);
      return IconStep.ended;
    }
    final target = choose(read!, here);
    if (target == null) {
      if (_moved) {
        await _homeFlow(first: read);
      } else {
        _finish('none free');
      }
      return IconStep.ended;
    }
    // The journal knows first: the icon may be at either place until the move has landed.
    final was = _placed;
    _write(target, was: was);
    moves++;
    await icons.move(id, target.$1, target.$2);
    final after = await _look();
    final now = after?.find(id);
    if (after == null) return _lost('failed', keep: true);
    if (now == null) return _lost('left (moved)');
    final at = (now.x, now.y);
    if (at == was) {
      // It did not move at all.
      if (_moved) {
        await _homeFlow(first: after);
      } else {
        _finish('not moved');
      }
      return IconStep.ended;
    }
    _placed = at;
    _moved = true;
    _write(at);
    return IconStep.moved;
  });

  /// The ending: a move to `home`, with the read before it and the read back after. The visit is over afterwards.
  Future<void> pushHome() => _enqueue(() async {
    if (_id == null) return;
    await _homeFlow();
  });

  /// Reads the desktop for the next step (counted).
  Future<IconsRead?> _look() {
    reads++;
    return icons.read();
  }

  /// The icon as [read] shows it, when it is where this visit left it and the desktop is as it was; else the visit is over
  /// (null): nothing is touched again.
  DesktopIcon? _verify(IconsRead? read, String id) {
    if (read == null) {
      _lost('failed', keep: _moved);
      return null;
    }
    final here = read.find(id);
    if (here == null) {
      _lost('left (moved)');
      return null;
    }
    if (read.autoArrange) {
      _lost('auto-arrange');
      return null;
    }
    if ((here.x, here.y) != _placed) {
      _lost('left (moved)');
      return null;
    }
    return here;
  }

  /// Somebody else's icon now (or one that cannot be seen): the visit ends and the icon is left as it is. The journal stays
  /// only when the icon could not be seen and may be away from home ([keep]).
  IconStep _lost(String result, {bool keep = false}) {
    _finish(result, keepJournal: keep);
    return IconStep.ended;
  }

  /// Read, move home, read back; once more if it is not home and still where it was put. Ends the visit.
  Future<void> _homeFlow({IconsRead? first}) async {
    final id = _id;
    if (id == null) return;
    final read = first ?? await _look();
    final here = read?.find(id);
    if (read == null) {
      _finish('failed', keepJournal: _moved);
      return;
    }
    if (here == null) {
      _finish('left (moved)');
      return;
    }
    final at = (here.x, here.y);
    if (at == _home) {
      _finish(_moved ? homeOk : 'not moved');
      return;
    }
    if (read.autoArrange || at != _placed) {
      // Somebody else's now (or the shell lays icons out by itself): never touched again.
      _finish(read.autoArrange ? 'auto-arrange' : 'left (moved)');
      return;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      moves++;
      await icons.move(id, _home.$1, _home.$2);
      final after = await _look();
      final now = after?.find(id);
      if (after == null) {
        _finish('failed', keepJournal: true);
        return;
      }
      if (now == null) {
        _finish('left (moved)');
        return;
      }
      final where = (now.x, now.y);
      if (where == _home) {
        _finish(homeOk);
        return;
      }
      if (where != _placed) {
        _finish('left (moved)');
        return;
      }
    }
    // Still where it was put and the shell will not take it home: the journal stays for the next start.
    _finish('failed', keepJournal: true);
  }

  // ---- ending early ----

  /// Everything that sends the icon home at once: if it is still at `placed` it goes back. Queued after any step in flight.
  void abort() {
    if (!active || _ending) return;
    _ending = true;
    unawaited(_enqueue(() async => _homeFlow()));
  }

  /// The gate or the switches changed: a visit that may no longer run goes home.
  void recheck() {
    if (active && !allowed()) abort();
  }

  /// Quitting, or Windows ending the session: home at once. The journal stays until the icon has been seen home, so a quit
  /// that can't wait for it leaves the next start to finish the job.
  void putBack() => abort();

  /// [putBack], and a future that ends once the visit has (quitting waits for it: MochiDesktop.addExitTask); null when no
  /// visit is running (nothing to wait for).
  Future<void>? settle() {
    if (!active) return null;
    abort();
    return _tail;
  }

  /// Something that must stop the visit before the next move: the desktop in use, a mouse button down, the gate closed.
  bool blocked() => !allowed() || icons.mouseDown() || icons.usingDesktop();

  /// Serialises the visit's shell calls: one after another, never overlapping, and never throwing.
  Future<T> _enqueue<T>(Future<T> Function() step) {
    final done = _tail.then((_) => step());
    _tail = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  void _finish(String result, {bool keepJournal = false}) {
    if (!keepJournal) _store.delete();
    lastResult = result;
    log?.call('icons: $result');
    _id = null;
    _moved = false;
    _ending = false;
  }

  // ---- the journal ----

  void _write((int, int) placed, {(int, int)? was}) {
    final id = _id;
    if (id == null) return;
    _store.write(IconRecord(id: id, home: _home, placed: placed, was: was).toJson());
  }

  /// A visit that was cut short (a crash, a kill, a power cut) leaves its journal: an icon with that id that is at `placed`
  /// (or `was`) goes back to `home`; the journal goes either way. True when an icon was moved.
  Future<bool> recover({bool keepVisit = false}) async {
    if (active && !keepVisit) return false;
    final json = _store.read();
    if (json == null) return false;
    final record = IconRecord.fromJson(json);
    var moved = false;
    if (record != null) {
      final read = await _look();
      final here = read?.find(record.id);
      if (read != null && here != null && !read.autoArrange) {
        final at = (here.x, here.y);
        if (at != record.home && (at == record.placed || at == record.was)) {
          moves++;
          moved = await icons.move(record.id, record.home.$1, record.home.$2);
          log?.call('icons: recovered an icon (${moved ? 'home ok' : 'failed'})');
        }
      }
    }
    _store.delete();
    return moved;
  }

  void dispose() {
    putBack();
  }
}

/// Where Mochi is and what it does at one moment of a visit (feet in physical pixels).
@immutable
class IconFrame {
  const IconFrame({required this.feet, required this.facing, required this.animation, required this.time, required this.oneShot, this.accent});

  final (int, int) feet;
  final double facing;
  final PetAnimation animation;

  /// Seconds into [animation] (the clock for a loop).
  final double time;
  final bool oneShot;
  final void Function(PetPose pose)? accent;
}

enum _Phase { leap, sit, kick, hop, pleased, push, hopBack, done }

/// What Mochi does on the way to, on and off one icon (the nudger does the moving; this is the acting). It runs on the
/// world's clock, ticked by the adventure; the shell's answers arrive in between and are picked up on the next tick.
class IconVisit {
  IconVisit({
    required this.nudger,
    required this.read,
    required this.icon,
    required this.from,
    required this.facing,
    required this.screen,
    required this.windows,
    required this.scale,
    required double now,
    this.sit = 3,
  }) : _phaseAt = now {
    _top = IconRules.top(read, icon);
    _hopFrom = from;
    _hopTo = _top;
    _length = leapSeconds(from, _top, scale);
  }

  final IconNudger nudger;

  /// The desktop when the icon was chosen, the icon, where Mochi's feet were, and the way it faces.
  final IconsRead read;
  final DesktopIcon icon;
  final (int, int) from;
  double facing;

  /// The display, the windows that may cover the desktop, and the display's scale.
  final PixelRect screen;
  final List<PixelRect> windows;
  final double scale;

  /// How long it sits on the icon before it kicks (seconds, 2–4).
  final double sit;

  /// How long it sits looking pleased, and how long a kick or a push takes at least.
  static const double pleasedFor = 2;
  static const double kickFor = 0.6;
  static const double hopFor = 0.4;

  _Phase _phase = _Phase.leap;
  double _phaseAt;
  late (int, int) _top, _hopFrom, _hopTo;
  late double _length;
  (int, int) _feet = (0, 0);

  /// The answer of the step in flight, when it has come.
  bool _asked = false;
  IconStep? _stepped;
  bool _pushed = false;

  /// The visit is over (Mochi drops off where it is).
  bool get finished => _phase == _Phase.done;

  /// Mochi's feet now.
  (int, int) get feet => _feet;

  /// The leap's length (seconds): longer for a farther icon, at most 1.4.
  static double leapSeconds((int, int) a, (int, int) b, double scale) {
    final distance = math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2)) / math.max(0.5, scale);
    return (0.45 + distance / 1500).clamp(0.45, 1.4);
  }

  /// The visit is cut short: the icon goes home (if it was moved) and Mochi is done.
  void abort() {
    nudger.abort();
    _phase = _Phase.done;
  }

  void _to(_Phase phase, double now) {
    _phase = phase;
    _phaseAt = now;
    _asked = false;
    _stepped = null;
    _pushed = false;
  }

  /// Mochi's place at [now], moving the visit on; null once it is over.
  IconFrame? frame(double now) {
    if (_phase == _Phase.done) return null;
    final elapsed = now - _phaseAt;
    switch (_phase) {
      case _Phase.leap:
        if (elapsed >= _length) {
          _feet = _top;
          _to(_Phase.sit, now);
          return _sitFrame(now);
        }
        return _leapFrame(elapsed / _length, elapsed);
      case _Phase.sit:
        if (elapsed >= sit) {
          _to(_Phase.kick, now);
          return _kickFrame(0);
        }
        return _sitFrame(now);
      case _Phase.kick:
        if (!_asked) {
          _asked = true;
          unawaited(
            nudger.kick((fresh, at) => IconRules.kickTarget(fresh, at, facing: facing, screen: screen, windows: windows)).then((step) {
              _stepped = step;
            }),
          );
        }
        final step = _stepped;
        if (step != null && elapsed >= kickFor) {
          if (step == IconStep.moved && nudger.active) {
            final placed = nudger.placed!;
            final target = IconRules.top(read, DesktopIcon(icon.id, placed.$1, placed.$2));
            _hopFrom = _feet;
            _hopTo = target;
            _top = target;
            _to(_Phase.hop, now);
            return _leapFrameTo(0, 0);
          }
          _phase = _Phase.done;
          return null;
        }
        return _kickFrame(elapsed);
      case _Phase.hop:
        if (elapsed >= hopFor) {
          _feet = _hopTo;
          _to(_Phase.pleased, now);
          return _pleasedFrame(now);
        }
        return _leapFrameTo(elapsed / hopFor, elapsed);
      case _Phase.pleased:
        if (elapsed >= pleasedFor) {
          final placed = nudger.placed;
          if (!nudger.active || placed == null) {
            _phase = _Phase.done;
            return null;
          }
          facing = nudger.home!.$1 >= placed.$1 ? 1 : -1;
          _to(_Phase.push, now);
          return _kickFrame(0);
        }
        return _pleasedFrame(now);
      case _Phase.push:
        if (!_asked) {
          _asked = true;
          unawaited(
            nudger.pushHome().then((_) {
              _pushed = true;
            }),
          );
        }
        if (_pushed && elapsed >= kickFor) {
          if (nudger.lastResult == IconNudger.homeOk) {
            // The icon is home: Mochi follows it there.
            _hopFrom = _feet;
            _hopTo = IconRules.top(read, icon);
            _to(_Phase.hopBack, now);
            return _leapFrameTo(0, 0);
          }
          _phase = _Phase.done;
          return null;
        }
        return _kickFrame(elapsed);
      case _Phase.hopBack:
        if (elapsed >= hopFor) {
          _feet = _hopTo;
          _phase = _Phase.done;
          return null;
        }
        return _leapFrameTo(elapsed / hopFor, elapsed);
      case _Phase.done:
        return null;
    }
  }

  IconFrame _sitFrame(double now) => IconFrame(feet: _feet = _top, facing: facing, animation: PetAnimation.sit, time: now, oneShot: false);

  IconFrame _pleasedFrame(double now) => IconFrame(
    feet: _feet = _top,
    facing: facing,
    animation: PetAnimation.sit,
    time: now,
    oneShot: false,
    accent: (pose) {
      pose.eyes = PetEyes.happy;
      pose.earPerk = math.max(pose.earPerk, 0.6);
    },
  );

  /// A swing of the paw, over and over while the shell works.
  IconFrame _kickFrame(double elapsed) => IconFrame(feet: _feet = _top, facing: facing, animation: PetAnimation.bat, time: elapsed % kickFor, oneShot: true);

  /// The first leap, from where Mochi was to the icon.
  IconFrame _leapFrame(double k, double elapsed) => _arc(_hopFrom, _hopTo, k, elapsed, _length);

  /// A hop from [_hopFrom] to [_hopTo].
  IconFrame _leapFrameTo(double k, double elapsed) => _arc(_hopFrom, _hopTo, k, elapsed, hopFor);

  IconFrame _arc((int, int) a, (int, int) b, double k, double elapsed, double length) {
    final t = k.clamp(0.0, 1.0);
    final distance = math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));
    final height = (distance * 0.25).clamp(24.0 * scale, 160.0 * scale);
    final x = a.$1 + (b.$1 - a.$1) * t;
    final y = a.$2 + (b.$2 - a.$2) * t - 4 * height * t * (1 - t);
    final to = (b.$1 - a.$1).sign;
    _feet = (x.round(), y.round());
    return IconFrame(feet: _feet, facing: to == 0 ? facing : to.toDouble(), animation: PetAnimation.excitedJump, time: math.min(elapsed, length), oneShot: true);
  }
}
