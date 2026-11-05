// The phone's hold-to-talk: Sources/TamagotchiCore/Animation/ListeningPose.swift and the sound
// waves from iOS/MochiPocket/RoomView.swift.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'drawing.dart';
import 'model/ease.dart';
import 'model/poses.dart';
import 'scene_layout.dart';

/// Mochi turning to listen where it stands: the head swivels so its right ear and shoulder come
/// forward, that ear stands up tall towards you and the other folds back.
abstract final class ListeningPose {
  /// How long the turn takes.
  static const double turnDuration = 0.55;

  /// The listening pose built on `idle` (Swift evaluates the idle loop at `time` itself; until the
  /// evaluators are ported, pass the idle pose for that moment). `elapsed` counts from the start of
  /// the turn; once `listening`, Mochi concentrates with a slow sway and small ear flicks.
  static PetPose pose(PetPose idle, {required double elapsed, required bool listening, required double time}) {
    final turn = listening ? 1.0 : Ease.smooth(math.min(1, elapsed / turnDuration));
    final pose = idle.copy()
      ..x = 0
      ..y = 0
      ..facing = 1
      ..headTurn = turn
      ..earListen = turn;
    pose.earPerk = Ease.lerp(pose.earPerk, 0.9, turn);
    // The right shoulder leads: the body leans and tips towards the listening ear.
    pose
      ..lean = -0.11 * turn
      ..rotation = -0.1 * turn
      ..tilt = -0.16 * turn
      // Concentrating: eyes up, brows raised.
      ..lookX = 0.1 * turn
      ..lookY = -0.35 * turn
      ..brows = turn > 0.5 ? Brows.raised : pose.brows
      ..eyeScale = 1 + 0.05 * turn
      ..mouth = PetMouth.cat;
    if (listening) {
      pose.tilt += 0.02 * math.sin(time * 1.6);
      pose.earLeft = -0.09 * Ease.bump((time * 0.7).remainder(1), 0, 0.14);
    } else {
      // A little settle as the turn finishes.
      pose.scaleY *= 1 - 0.03 * Ease.bump(elapsed, turnDuration * 0.7, turnDuration * 1.3);
    }
    return pose;
  }

  /// Sound arriving at Mochi's listening ear (`RoomView.drawSoundWaves`); `appear` 0…1 fades
  /// them in during the turn. `tint` is the phone's accent colour (Mochi Pocket's `Theme.tint`).
  static void drawSoundWaves(GContext g, SceneLayout layout, double time, double appear, {Color? tint}) {
    final color = tint ?? hex(0xB4471C);
    final ear = Offset(layout.petHome - 20 * layout.scale, layout.ground - 55 * layout.scale);
    for (var index = 0; index < 3; index++) {
      final phase = (time * 0.85 + index / 3).remainder(1);
      final radius = (10 + (1 - phase) * 30) * layout.scale;
      final arc = Path()..arc(ear, radius, degrees(148), degrees(212));
      g.stroke(arc, color.fade(0.6 * math.sin(math.pi * phase) * appear), 2.5, join: StrokeJoin.miter);
    }
  }
}
