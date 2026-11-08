// Feel the purr (Sprint 2 W21), the Mac's PurrSession (Sources/App/Services/PurrSession.swift) for PCs, which have no
// Force Touch trackpad: press and hold Mochi (on the taskbar, on the desktop, or in its room in the popover and Mochi's
// window) and it keeps purring. It's petted when you press and again every 3 seconds you hold on (the friendship's
// daily caps apply, as on the Mac), little purr lines tremble at its sides, and, with Mochi's sounds on, a soft purr
// plays in bursts about a breath apart. Letting go ends it; so does half a minute without moving, as on the Mac.
// Settings › Fun › Touch has the Mac's switch (`hapticPurr`): here it's the purr's sound.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_world/mochi_world.dart' as w show Effect, EffectKind, PetPose;

import 'desktop_settings.dart';
import 'notifications.dart';
import 'pc_rhythm.dart';
import 'sounds.dart';

class PurrSession extends ChangeNotifier {
  PurrSession({
    required this.settings,
    required this.sounds,
    required this.rhythm,
    required void Function() pet,
    required double Function() time,
    DateTime Function()? clock,
  }) : _pet = pet,
       _time = time,
       _clock = clock ?? DateTime.now;

  final DesktopSettings settings;
  final MochiSounds sounds;
  final PcRhythm rhythm;
  final void Function() _pet;
  final double Function() _time;
  final DateTime Function() _clock;

  /// Nobody holds on longer than this without moving; stop rather than purr forever.
  static const double longest = 30;

  /// A burst of purring about a breath apart; Mochi is petted again this often while you hold on.
  static const Duration burst = Duration(milliseconds: 900);
  static const double petEvery = 3;

  Timer? _timer;
  Timer? _release;
  double _startedAt = 0;
  double _pettedAt = 0;

  /// Bursts of the purr sound played this session (tests).
  int bursts = 0;

  /// Mochi is purring.
  bool get active => _timer != null;

  /// Seconds since it began (the purr lines' clock).
  double get elapsed => active ? _time() - _startedAt : 0;

  /// You pressed and held Mochi: it's petted, and it purrs until you let go.
  void begin() {
    if (_timer != null) return;
    _release?.cancel();
    _startedAt = _pettedAt = _time();
    bursts = 0;
    _pet();
    _purr();
    _timer = Timer.periodic(burst, (_) => _step());
    notifyListeners();
  }

  /// You let go.
  void end() {
    _release?.cancel();
    _release = null;
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  /// A moment's purr without holding on (the screen reader's action): a few seconds, then it ends on its own.
  void pulse([Duration length = const Duration(seconds: 3)]) {
    begin();
    _release?.cancel();
    _release = Timer(length, end);
  }

  void _step() {
    final now = _time();
    if (now - _startedAt > longest) return end();
    if (now - _pettedAt >= petEvery) {
      _pettedAt = now;
      _pet();
    }
    _purr();
  }

  /// The purr's sound: with Mochi's sounds and the purr on, outside quiet mode and hours, while the screen can be seen.
  void _purr() {
    if (!settings.soundEnabled || !settings.purrSound || rhythm.unseen) return;
    if (NotificationPolicy.isQuiet(settings, _clock())) return;
    if (sounds.play(SoundCue.purr, force: true)) bursts++;
  }

  /// [pose] with the purr lines trembling at Mochi's sides ([time]: seconds; still with animations off).
  static w.PetPose decorate(w.PetPose pose, double time, {bool calm = false}) {
    final purring = pose.copy();
    final phase = calm ? 0.0 : time;
    final swell = calm ? 1.0 : 0.8 + 0.2 * math.sin(time * 9);
    purring.effects = [
      ...pose.effects.where((effect) => effect.kind != w.EffectKind.purr),
      w.Effect(w.EffectKind.purr, x: -0.62, y: 0.45, scale: 0.95, opacity: swell, variant: 0, phase: phase),
      w.Effect(w.EffectKind.purr, x: 0.62, y: 0.45, scale: 0.95, opacity: swell, variant: 1, phase: phase),
    ];
    return purring;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _release?.cancel();
    super.dispose();
  }
}
