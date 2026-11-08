// Peekaboo out on the desktop (docs/SPRINT_2.md X3, Mischief): with the switch on, Mochi's stage actor isn't topmost. It
// sits in the window stack just below the window you're using (NativeStage.below), so that window always covers it and
// Mochi peeks out from behind its edges; when the window with the focus is one of Mochi's own, the desktop or the
// taskbar, it just sits at the top of the normal band. With the switch off the actor stays topmost, as before.
//
// - Only while Mochi is out (the adventure, the screen roamer: the first picture of the actor starts it, hiding the
//   actor stops it) and the screen can be seen: the foreground window is read three times a second (the adventure's
//   survey rate) and the actor is placed again only when it changes. Nothing is read while Mochi is home, while the
//   switch is off or while nobody can see the screen.
// - Only a window handle and its kind are read ([ForegroundWindows]); nothing is ever moved, raised or focused.

import 'dart:async';

import '../../core/mischief.dart';
import '../../core/pc_rhythm.dart';
import '../../platform/foreground_window.dart';
import '../../platform/native_stage.dart';
import 'stage_pet.dart';

class StageBehind {
  StageBehind({required this.stage, required this.gate, required this.rhythm, required this.foreground});

  final NativeStage stage;
  final MischiefGate gate;
  final PcRhythm rhythm;
  final ForegroundWindows foreground;

  /// How often the foreground window is read while Mochi is out (per second): the adventure's survey rate.
  static const double rate = 3;

  StagePet? _pet;
  Timer? _timer;
  ForegroundWindow? _last;
  bool _was = false;

  /// Foreground reads so far (tests, the perf meter).
  int reads = 0;

  /// Mochi's actor hides behind the foreground window now (Peekaboo is on and allowed).
  bool get active => gate.may(MischiefExtra.peekaboo);

  /// The actor is topmost (as every actor is, unless Peekaboo is on).
  bool get topmost => !active;

  /// The foreground window is being read (tests: no timer while Mochi is home).
  bool get watching => _timer != null;

  /// Mochi goes out: the foreground window is read from now on.
  void start(StagePet pet) {
    if (_timer != null) return;
    _pet = pet;
    _timer = Timer.periodic(Duration(milliseconds: (1000 / rate).round()), (_) => look());
    look();
  }

  /// Mochi is home again (or nobody can see the screen): nothing is read.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _pet = null;
    _last = null;
    _was = false;
  }

  /// The actor was just shown afresh (its window is new or was hidden): place it again now.
  void placed() {
    _last = null;
    if (_timer != null) look();
  }

  /// Reads the foreground window and places the actor if it changed.
  void look() {
    final pet = _pet;
    if (pet == null || rhythm.unseen) return;
    final on = active;
    if (on != _was) {
      // The switch came on or went off: the actor's picture is shown again, topmost or not, before it is placed.
      _was = on;
      _last = null;
      pet.replace();
    }
    if (!on || !pet.shown) {
      _last = null;
      return;
    }
    reads++;
    final window = foreground.read();
    if (window == null || window == _last) return;
    _last = window;
    if (window.kind == ForegroundKind.app) {
      stage.below(pet.actor, window.hwnd);
    } else {
      // Ours, the desktop or the shell: the top of the normal band, below the always-on-top windows.
      stage.raise([pet.actor]);
    }
  }
}
