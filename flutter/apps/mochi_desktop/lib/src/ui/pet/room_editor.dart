// Decorating Mochi's room (Sprint 2 W18), the Mac's RoomEditorView over the room: a tray of the twelve pieces at the
// top (locked ones greyed with a lock and how to earn them, all of them while the room is full), dragged into the room
// or clicked to add at a free spot; placed pieces dragged about (wall pieces stay on the wall, floor pieces on the
// floor; the band they may go in lights up), selected to flip or put away, and dropped back on the tray to put away.
// From the keyboard: Tab to a piece in the tray and Enter to add it; Tab to a placed piece, the arrow keys to move it,
// F to flip it and Delete to put it away; Escape or Done when you're finished. Nobody is petted while decorating.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/room.dart';
import '../../desktop.dart';

/// A piece of furniture drawn to fit a small square (the tray, Settings): the Mac's FurnitureIcon.
class FurnitureIcon extends StatelessWidget {
  const FurnitureIcon({super.key, required this.kind, this.size = 22});

  final FurnitureKind kind;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _FurnitureIconPainter(kind, dark: Theme.of(context).brightness == Brightness.dark)),
  );
}

class _FurnitureIconPainter extends CustomPainter {
  _FurnitureIconPainter(this.kind, {required this.dark});

  final FurnitureKind kind;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final k = math.min((size.width - 2) / kind.width, (size.height - 2) / kind.height);
    final standing = kind.placement == FurniturePlacement.floor && !kind.isFlat;
    final g = GContext(canvas)
      ..translateBy(size.width / 2, standing ? size.height / 2 + kind.height * k / 2 : size.height / 2)
      ..scaleBy(k, k);
    FurnitureArt.draw(kind.id, g, dark: dark, time: 1.2);
  }

  @override
  bool shouldRepaint(_FurnitureIconPainter old) => old.kind.id != kind.id || old.dark != dark;
}

/// The editor over a room drawn with [layout].
class RoomEditorOverlay extends StatefulWidget {
  const RoomEditorOverlay({super.key, required this.desktop, required this.layout});

  final MochiDesktop desktop;
  final SceneLayout layout;

  /// The tray's bottom edge (scene points): a piece dropped above it is put away.
  static const double trayBottom = 40;

  @override
  State<RoomEditorOverlay> createState() => _RoomEditorOverlayState();
}

class _RoomEditorOverlayState extends State<RoomEditorOverlay> {
  final GlobalKey _box = GlobalKey();
  final FocusNode _focus = FocusNode(debugLabel: 'Decorate');

  RoomEditor get editor => widget.desktop.room;
  RoomSpace get space => RoomSpace(widget.layout);

  @override
  void initState() {
    super.initState();
    editor.addListener(_keepKeys);
  }

  /// The keys stay with the editor (Escape is done) when a button that had them goes away (a piece put away).
  void _keepKeys() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && editor.isEditing && !_focus.hasFocus) _focus.requestFocus();
  });

  @override
  void dispose() {
    editor.removeListener(_keepKeys);
    _focus.dispose();
    super.dispose();
  }

  Offset _local(Offset global) {
    final box = _box.currentContext?.findRenderObject();
    return box is RenderBox ? box.globalToLocal(global) : global;
  }

  /// Where [kind]'s anchor would land for a raw anchor, snapped into its band.
  Offset _snapped(Offset raw, FurnitureKind kind) {
    final (x, y) = space.position(raw, kind);
    return space.anchor(PlacedFurniture(id: '', kind: kind.id, x: x, y: y), kind);
  }

  /// A new piece held by its middle: a standing piece's anchor is its foot, below the pointer.
  Offset _holding(FurnitureKind kind, Offset pointer) {
    if (kind.placement == FurniturePlacement.floor && !kind.isFlat) {
      return Offset(pointer.dx, pointer.dy + kind.height * space.scale(kind, RoomLayout.floorBand.$1) / 2);
    }
    return pointer;
  }

  void _follow(Offset pointer) {
    final drag = editor.drag;
    if (drag == null) return;
    final raw = pointer + drag.grabOffset;
    editor.follow(anchor: _snapped(raw, drag.kind), overTray: pointer.dy < RoomEditorOverlay.trayBottom);
  }

  void _commit({bool outside = false}) {
    final drag = editor.drag;
    if (drag == null) return;
    if (outside) editor.follow(anchor: drag.anchor, overTray: true);
    editor.drop(space.position(editor.drag!.anchor, drag.kind));
  }

  /// A placed piece moved from the keyboard, a step at a time.
  void _nudge(PlacedFurniture item, FurnitureKind kind, double dx, double dy) =>
      editor.move(item.id, RoomLayout.snapped(kind, item.x + dx, item.y + dy));

  KeyEventResult _keys(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      editor.end();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([editor, widget.desktop.settings, widget.desktop.world]),
    builder: (context, _) {
      final room = editor.room;
      final drag = editor.drag;
      final selected = editor.selection == null ? null : room.items.where((item) => item.id == editor.selection).firstOrNull;
      final selectedKind = selected == null ? null : FurnitureCatalog.kind(selected.kind);
      return Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _keys,
        child: Stack(
          key: _box,
          clipBehavior: Clip.hardEdge,
          children: [
            // Clicks on empty space deselect, and nobody gets petted while decorating.
            Positioned.fill(
              child: Semantics(
                label: 'Decorating ${widget.desktop.settings.petName}’s room',
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => editor.selection = null),
              ),
            ),
            if (drag != null)
              Positioned.fill(
                key: const ValueKey('band'),
                child: IgnorePointer(child: CustomPaint(painter: _BandPainter(drag.kind, space, context.palette.tint))),
              ),
            for (final item in room.drawingOrder)
              if (FurnitureCatalog.kind(item.kind) case final kind?) _handle(item, kind),
            if (drag == null && selected != null && selectedKind != null) ..._chrome(context, selected, selectedKind),
            if (drag != null)
              Positioned.fill(
                key: const ValueKey('lifted'),
                child: IgnorePointer(
                  child: Opacity(
                    opacity: drag.overTray ? 0.35 : 0.92,
                    child: CustomPaint(
                      painter: _LiftedPainter(drag, space, dark: Theme.of(context).brightness == Brightness.dark),
                    ),
                  ),
                ),
              ),
            Positioned(key: const ValueKey('tray'), left: Space.xs, right: Space.xs, top: 5, child: Center(child: _tray(context, room))),
          ],
        ),
      );
    },
  );

  // MARK: Pieces in the room

  Widget _handle(PlacedFurniture item, FurnitureKind kind) {
    final frame = space.frame(item, kind);
    final rect = Rect.fromCenter(center: frame.center, width: math.max(frame.width, 18), height: math.max(frame.height, 14));
    // Keyed: the piece being dragged keeps its gesture while the band and the carried piece come and go around it.
    return Positioned.fromRect(
      key: ValueKey('piece ${item.id}'),
      rect: rect,
      child: Semantics(
        button: true,
        selected: editor.selection == item.id,
        label: kind.title,
        hint: 'Drag to move. Arrow keys move it, F flips it, Delete puts it away.',
        child: Tooltip(
          message: '${kind.title} — drag to move',
          child: Focus(
            onFocusChange: (focused) {
              if (focused && editor.drag == null) editor.selection = item.id;
            },
            onKeyEvent: (node, event) {
              if (event is KeyUpEvent) return KeyEventResult.ignored;
              final step = 0.02;
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.arrowLeft) _nudge(item, kind, -step, 0);
              if (key == LogicalKeyboardKey.arrowRight) _nudge(item, kind, step, 0);
              if (key == LogicalKeyboardKey.arrowUp) _nudge(item, kind, 0, -step);
              if (key == LogicalKeyboardKey.arrowDown) _nudge(item, kind, 0, step);
              if (key == LogicalKeyboardKey.keyF && event is KeyDownEvent) editor.flip(item.id);
              if ((key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) && event is KeyDownEvent) {
                editor.remove(item.id);
                _focus.requestFocus();
              }
              final used = {
                LogicalKeyboardKey.arrowLeft,
                LogicalKeyboardKey.arrowRight,
                LogicalKeyboardKey.arrowUp,
                LogicalKeyboardKey.arrowDown,
                LogicalKeyboardKey.keyF,
                LogicalKeyboardKey.delete,
                LogicalKeyboardKey.backspace,
              };
              return used.contains(key) ? KeyEventResult.handled : KeyEventResult.ignored;
            },
            child: Builder(
              builder: (context) {
                final focused = Focus.of(context).hasFocus;
                return MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => editor.selection = item.id,
                    onPanStart: (details) {
                      final anchor = space.anchor(item, kind);
                      editor.lift(item, kind, anchor: anchor, grabOffset: anchor - _local(details.globalPosition));
                    },
                    onPanUpdate: (details) => _follow(_local(details.globalPosition)),
                    onPanEnd: (_) => _commit(),
                    onPanCancel: editor.cancelDrag,
                    child: focused
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: context.palette.focus, width: 2),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          )
                        : const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The selected piece: a dashed outline and its Flip and Put away buttons, above it (or below, near the tray).
  List<Widget> _chrome(BuildContext context, PlacedFurniture item, FurnitureKind kind) {
    final p = context.palette;
    final frame = space.frame(item, kind).inflate(3);
    final above = frame.top > RoomEditorOverlay.trayBottom + 26;
    final x = frame.center.dx.clamp(36.0, math.max(36.0, space.width - 36));
    final y = above ? frame.top - 14 : math.min(frame.bottom + 14, space.height - 14);
    Widget button(IconData icon, String tip, VoidCallback onPressed) => Tooltip(
      message: tip,
      child: Semantics(
        button: true,
        label: tip,
        excludeSemantics: true,
        child: InkResponse(
          onTap: onPressed,
          radius: 14,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), child: Icon(icon, size: 14, color: p.ink)),
        ),
      ),
    );
    return [
      Positioned.fromRect(key: const ValueKey('outline'), rect: frame, child: IgnorePointer(child: CustomPaint(painter: _DashedPainter(p.tint)))),
      Positioned(
        key: const ValueKey('controls'),
        left: x - 30,
        top: y - 12,
        width: 60,
        height: 24,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: p.surface.withValues(alpha: 0.96),
            shape: StadiumBorder(side: BorderSide(color: p.stroke)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              button(Icons.swap_horiz_rounded, 'Flip ${kind.title}', () => editor.flip(item.id)),
              button(Icons.close_rounded, 'Remove ${kind.title}', () => editor.remove(item.id)),
            ],
          ),
        ),
      ),
    ];
  }

  // MARK: Tray

  Widget _tray(BuildContext context, RoomLayout room) {
    final p = context.palette;
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 3, 4, 3),
        decoration: ShapeDecoration(
          color: p.surface.withValues(alpha: 0.97),
          shape: StadiumBorder(side: BorderSide(color: p.stroke)),
          shadows: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 3, offset: const Offset(0, 1))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final kind in FurnitureCatalog.all) _trayItem(context, kind, room),
            Container(width: 1, height: 16, margin: const EdgeInsets.symmetric(horizontal: 4), color: p.stroke),
            Tooltip(
              message: 'Up to ${RoomLayout.maxItems} pieces fit in the room',
              child: Text(
                '${room.items.length}/${RoomLayout.maxItems}',
                style: context.type.caption.copyWith(fontSize: 10, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            const SizedBox(width: 4),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 24),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                visualDensity: VisualDensity.compact,
                textStyle: context.type.caption.copyWith(fontWeight: FontWeight.w700),
              ),
              onPressed: editor.end,
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trayItem(BuildContext context, FurnitureKind kind, RoomLayout room) {
    final unlocked = kind.isUnlocked(editor.progress);
    final available = unlocked && !room.isFull;
    final help = !unlocked
        ? '${kind.title} — ${kind.unlockHint}'
        : room.isFull
        ? '${kind.title} — the room is full; put something away first'
        : '${kind.title} — drag into the room, or click to add';
    final icon = Opacity(
      opacity: available ? 1 : (unlocked ? 0.45 : 0.3),
      child: ColorFiltered(
        colorFilter: unlocked ? const ColorFilter.mode(Colors.transparent, BlendMode.dst) : _greyscale,
        child: FurnitureIcon(kind: kind),
      ),
    );
    return Tooltip(
      message: help,
      child: Semantics(
        button: true,
        enabled: available,
        label: kind.title,
        hint: help,
        excludeSemantics: true,
        child: InkResponse(
          onTap: available ? () => editor.add(kind) : null,
          radius: 16,
          child: GestureDetector(
            onPanStart: available
                ? (details) {
                    final pointer = _local(details.globalPosition);
                    final hold = _holding(kind, pointer);
                    editor.pickUp(kind, anchor: hold, grabOffset: hold - pointer);
                    _follow(pointer);
                  }
                : null,
            onPanUpdate: available ? (details) => _follow(_local(details.globalPosition)) : null,
            onPanEnd: available
                ? (details) {
                    final box = _box.currentContext?.size ?? Size.zero;
                    final drag = editor.drag;
                    final pointer = drag == null ? Offset.zero : drag.anchor - drag.grabOffset;
                    _commit(outside: !(Offset.zero & box).contains(pointer));
                  }
                : null,
            onPanCancel: available ? editor.cancelDrag : null,
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  icon,
                  if (!unlocked) Positioned(right: -1, bottom: -1, child: Icon(Icons.lock_rounded, size: 8, color: context.palette.inkSecondary)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const ColorFilter _greyscale = ColorFilter.matrix([
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0,
  ]);
}

/// Where the dragged piece may go: the wall's band or the floor's.
class _BandPainter extends CustomPainter {
  _BandPainter(this.kind, this.space, this.tint);

  final FurnitureKind kind;
  final RoomSpace space;
  final Color tint;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect;
    switch (kind.placement) {
      case FurniturePlacement.wall:
        rect = Rect.fromLTWH(
          4,
          space.height * RoomLayout.wallBand.$1 - 14,
          space.width - 8,
          space.height * (RoomLayout.wallBand.$2 - RoomLayout.wallBand.$1) + 28,
        );
      case FurniturePlacement.floor:
        rect = Rect.fromLTWH(4, space.layout.ground - 3, space.width - 8, space.height - space.layout.ground + 1);
    }
    final shape = Shapes.roundedRect(rect, 6);
    final g = GContext(canvas);
    g.fill(shape, tint.withValues(alpha: 0.07));
    g.stroke(shape, tint.withValues(alpha: 0.55), 1, dash: const [4, 3]);
  }

  @override
  bool shouldRepaint(_BandPainter old) => old.kind.id != kind.id || old.space.layout != space.layout || old.tint != tint;
}

/// A dashed outline around the selected piece.
class _DashedPainter extends CustomPainter {
  _DashedPainter(this.tint);

  final Color tint;

  @override
  void paint(Canvas canvas, Size size) => GContext(canvas).stroke(Shapes.roundedRect(Offset.zero & size, 5), tint, 1.2, dash: const [3, 2]);

  @override
  bool shouldRepaint(_DashedPainter old) => old.tint != tint;
}

/// The carried piece, drawn above everything until it's dropped.
class _LiftedPainter extends CustomPainter {
  _LiftedPainter(this.drag, this.space, {required this.dark});

  final RoomDrag drag;
  final RoomSpace space;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final (x, y) = space.position(drag.anchor, drag.kind);
    final item = PlacedFurniture(id: 'lifted', kind: drag.kind.id, x: x, y: y, flipped: drag.flipped);
    RoomDecor.drawPiece(item, drag.kind, GContext(canvas), space.layout, dark: dark, time: 1.2);
  }

  @override
  bool shouldRepaint(_LiftedPainter old) => old.drag != drag || old.dark != dark;
}
