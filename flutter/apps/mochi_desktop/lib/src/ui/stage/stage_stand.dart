// Mochi on the taskbar while Mochi's window is open (docs/SPRINT_2.md W26): the one Flutter window is Mochi's pages then, so the
// native stage (N1) draws Mochi where the pet's window would, at the same size and on the same feet line, and the taskbar
// stroll (ui/pet/taskbar_stroll.dart) goes on as if the pet's window were showing. It's the same Mochi as everywhere on the
// stage (StagePet), as an actor of its own: no Peekaboo behind the window you're using (that's Mochi out on the desktop).
//
// - The actor is clickable only on Mochi's own pixels (the stage hit-tests per pixel). A click does what a click on the tray's
//   icon does while Mochi's window is open (it shows Mochi's own page); a right-click is the pet's menu; there's no dragging.
// - It's topmost over the taskbar; the stroll puts it back there every half second and when the taskbar is clicked.
// - A frame is sent only when the picture or the place changes, and the stroll draws only while Mochi moves (and a few times
//   a second while it plays a one-shot), so a Mochi that sits costs nothing.

import 'dart:async';

import '../../platform/native_stage.dart';
import '../pet/stroller.dart' show StrollSample;
import '../pet/taskbar_stroll.dart' show TaskbarStand;
import 'stage_pet.dart';

class StageStand implements TaskbarStand {
  StageStand({required this.pet, required this.time, this.onTap, this.onMenu}) {
    _clicks = pet.stage.pointer.where((event) => event.actor == pet.actor).listen(_pointerEvent);
  }

  /// Mochi's actor on the stage.
  final StagePet pet;

  /// Mochi's world's clock (seconds): its poses loop on it.
  final double Function() time;

  /// A click on Mochi (what the tray icon's click does while Mochi's window is open), and a right-click (at [x], [y] on the
  /// screen: the pet's menu).
  final void Function()? onTap;
  final void Function(int x, int y)? onMenu;

  /// A press that moves this far (physical pixels) before it's let go isn't a click.
  static const int clickSlop = 8;

  late final StreamSubscription<StagePointer> _clicks;
  (int, int)? _pressed;

  @override
  bool get shown => pet.shown;

  @override
  bool show(StrollSample sample, {required (int, int) feet, required double ratio, required double unit}) =>
      pet.draw(time: time(), motion: sample, feet: feet, ratio: ratio, unit: unit);

  @override
  void raise() => pet.raise();

  @override
  void hide() {
    _pressed = null;
    pet.hide();
  }

  void _pointerEvent(StagePointer event) {
    switch (event.kind) {
      case StagePointerKind.down:
        _pressed = (event.screenX, event.screenY);
      case StagePointerKind.up:
        final pressed = _pressed;
        _pressed = null;
        if (pressed != null && (event.screenX - pressed.$1).abs() <= clickSlop && (event.screenY - pressed.$2).abs() <= clickSlop) {
          onTap?.call();
        }
      case StagePointerKind.rightUp:
        onMenu?.call(event.screenX, event.screenY);
      case StagePointerKind.cancel:
        _pressed = null;
      default:
        break;
    }
  }

  void dispose() {
    unawaited(_clicks.cancel());
    pet.dispose();
  }
}
