// The room makeover on this PC (Sprint 2 W18), the Mac's RoomEditorController (Sources/App/Features/Room): furniture
// you unlock with friendship and achievements, placed by dragging in Mochi's room (the popover's, as on the Mac, or the
// bigger one in Mochi's window). mochi_world's `RoomLayout` and `FurnitureCatalog` keep the rules (only unlocked
// pieces, at most eight, wall pieces on the wall and floor pieces on the floor, dropped on the tray to put away; checked
// against the Mac's fixture), and the room is kept in Settings under the Mac's key, `room`. mochi_art's `RoomSpace`
// maps it to whichever room shows it.

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;
import 'package:mochi_art/mochi_art.dart' show RoomDecor;
import 'package:mochi_world/mochi_world.dart' as w;

import 'desktop_settings.dart';
import 'desktop_world.dart';

/// A piece following the pointer (the Mac's RoomDrag).
@immutable
class RoomDrag {
  const RoomDrag({required this.kind, this.existing, this.flipped = false, this.grabOffset = Offset.zero, required this.anchor, this.overTray = false});

  final w.FurnitureKind kind;

  /// The placed piece being moved (null: a new one from the tray).
  final String? existing;
  final bool flipped;

  /// Anchor minus pointer, so the piece doesn't jump to the pointer.
  final Offset grabOffset;

  /// Where the piece would land, already snapped to its band (scene points).
  final Offset anchor;

  /// Over the tray: a new piece is cancelled, a placed one put away.
  final bool overTray;

  RoomDrag copyWith({Offset? anchor, bool? overTray}) => RoomDrag(
    kind: kind,
    existing: existing,
    flipped: flipped,
    grabOffset: grabOffset,
    anchor: anchor ?? this.anchor,
    overTray: overTray ?? this.overTray,
  );
}

class RoomEditor extends ChangeNotifier {
  RoomEditor({required this.settings, required this.world});

  final DesktopSettings settings;
  final DesktopWorld world;

  bool _editing = false;

  /// The room is being decorated: the tray shows over it, and nobody gets petted meanwhile.
  bool get isEditing => _editing;

  String? _selection;

  /// The piece showing its flip and remove buttons.
  String? get selection => _selection;
  set selection(String? id) {
    if (id == _selection) return;
    _selection = id;
    notifyListeners();
  }

  RoomDrag? _drag;

  /// The piece being dragged, from the tray or around the room.
  RoomDrag? get drag => _drag;

  w.RoomLayout get room => settings.room;
  w.ProgressState get progress => world.world.progress;

  void toggle() => _editing ? end() : begin();

  void begin() {
    if (_editing) return;
    _editing = true;
    notifyListeners();
  }

  void end() {
    if (!_editing && _drag == null && _selection == null) return;
    _editing = false;
    _selection = null;
    _drag = null;
    RoomDecor.liftedID = null;
    notifyListeners();
  }

  // MARK: Arranging

  /// Adds [kind] at [position] (normalized) or at a free spot near its usual place, if it's unlocked and there's room.
  w.PlacedFurniture? add(w.FurnitureKind kind, {(double, double)? position}) {
    final room = this.room;
    final placed = room.addUnlocked(kind, progress, x: position?.$1, y: position?.$2);
    if (placed == null) return null;
    settings.room = room;
    _selection = placed.id;
    notifyListeners();
    return placed;
  }

  void move(String id, (double, double) position) {
    final room = this.room..move(id, position.$1, position.$2);
    settings.room = room;
    notifyListeners();
  }

  void flip(String id) {
    final room = this.room..toggleFlip(id);
    settings.room = room;
    notifyListeners();
  }

  void remove(String id) {
    final room = this.room..remove(id);
    settings.room = room;
    if (_selection == id) _selection = null;
    notifyListeners();
  }

  /// Settings › Fun › Room › Clear Room.
  void clear() {
    settings.room = w.RoomLayout();
    _selection = null;
    notifyListeners();
  }

  // MARK: Dragging

  /// Lifts a placed piece out of the scene so the editor can carry it.
  void lift(w.PlacedFurniture item, w.FurnitureKind kind, {required Offset anchor, Offset grabOffset = Offset.zero}) {
    _selection = item.id;
    RoomDecor.liftedID = item.id;
    _drag = RoomDrag(kind: kind, existing: item.id, flipped: item.flipped, grabOffset: grabOffset, anchor: anchor);
    notifyListeners();
  }

  /// Picks a new piece up from the tray.
  void pickUp(w.FurnitureKind kind, {required Offset anchor, Offset grabOffset = Offset.zero}) {
    _selection = null;
    _drag = RoomDrag(kind: kind, grabOffset: grabOffset, anchor: anchor, overTray: true);
    notifyListeners();
  }

  /// The pointer moved: where the piece would land (snapped), and whether it's over the tray.
  void follow({required Offset anchor, required bool overTray}) {
    final drag = _drag;
    if (drag == null) return;
    _drag = drag.copyWith(anchor: anchor, overTray: overTray);
    notifyListeners();
  }

  /// Drops the dragged piece at [position] (normalized): a new one is added, a placed one moved, and anything dropped
  /// back on the tray is put away.
  void drop((double, double) position) {
    final drag = _drag;
    if (drag == null) return;
    _drag = null;
    RoomDecor.liftedID = null;
    final room = this.room;
    final placed = room.drop(drag.kind, existing: drag.existing, overTray: drag.overTray, x: position.$1, y: position.$2, progress: progress);
    settings.room = room;
    _selection = placed?.id;
    notifyListeners();
  }

  /// The drag was cancelled: nothing changes.
  void cancelDrag() {
    if (_drag == null) return;
    _drag = null;
    RoomDecor.liftedID = null;
    notifyListeners();
  }
}
