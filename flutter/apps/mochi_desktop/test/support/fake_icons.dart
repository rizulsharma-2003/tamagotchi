// A fake DesktopIcons for desktop icon play (X5): a desktop with icons at positions the test sets, every move the put-back
// contract asked for, and the ways Explorer misbehaves (snapping to a grid, a move that lands somewhere else, a refusing
// shell, a read that fails, a user who moves an icon while Mochi is on it).

import 'dart:async';

import 'package:mochi_desktop/src/platform/desktop_icons.dart';

class FakeIcons implements DesktopIcons {
  @override
  String? lastError;

  FakeIcons(Map<String, (int, int)> icons, {this.grid = true, this.autoArrange = false, this.hidden = false, this.cellWidth = 75, this.cellHeight = 100, this.iconSize = 48})
    : positions = Map.of(icons);

  /// Where each icon is (insertion order is the order they are listed in).
  final Map<String, (int, int)> positions;
  bool grid, autoArrange, hidden;
  int cellWidth, cellHeight, iconSize;
  bool more = false;

  /// Explorer's snap: where a move to (x, y) really lands (null: exactly there).
  (int, int) Function(String id, int x, int y)? snap;

  /// Icons the shell refuses to move (the call says false and nothing moves).
  final Set<String> refuse = {};

  /// How many more moves are quietly ignored (the call says true, the icon stays), and whether every move is.
  int ignoreNext = 0;
  bool ignoreAll = false;

  /// Reads fail (null).
  bool failReads = false;

  /// A read waits for [release] while this is set (the next read only).
  Completer<void>? hold;

  /// What Windows says about the mouse and the foreground window.
  bool mouse = false, desktopInUse = false;

  int reads = 0;
  final List<(String, int, int)> moves = [];

  /// Called just before each move lands (the journal can be looked at then).
  void Function(String id, int x, int y)? onMove;

  /// Called after each read (a user who moves an icon between steps).
  void Function()? onRead;

  List<(int, int)> movesOf(String id) => [
    for (final (i, x, y) in moves)
      if (i == id) (x, y),
  ];

  @override
  Future<IconsRead?> read() async {
    reads++;
    final wait = hold;
    if (wait != null) {
      hold = null;
      await wait.future;
    }
    onRead?.call();
    if (failReads) return null;
    return IconsRead(
      autoArrange: autoArrange,
      grid: grid,
      hidden: hidden,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      iconSize: iconSize,
      more: more,
      icons: [for (final MapEntry(key: id, value: at) in positions.entries) DesktopIcon(id, at.$1, at.$2)],
    );
  }

  @override
  Future<bool> move(String id, int x, int y) async {
    moves.add((id, x, y));
    if (!positions.containsKey(id) || refuse.contains(id)) return false;
    onMove?.call(id, x, y);
    if (ignoreAll) return true;
    if (ignoreNext > 0) {
      ignoreNext--;
      return true;
    }
    positions[id] = snap == null ? (x, y) : snap!(id, x, y);
    return true;
  }

  @override
  bool usingDesktop() => desktopInUse;

  @override
  bool mouseDown() => mouse;
}
