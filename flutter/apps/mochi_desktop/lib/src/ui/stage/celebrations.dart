// Full-screen celebrations (docs/SPRINT_2.md X10): confetti across your screen for Claude's big wins (graduation, a
// milestone, green tests or a green build: G2's Celebrations, from real live events only) and fireworks for streaks
// (days in a row with Claude Code on this PC), over the display you're on, on the native stage (N1).
//
// - Each piece of confetti and each spark is a tiny actor that lets every click through. Their pictures (a few shapes
//   and colours, six steps of a tumble; three sizes of spark) are drawn once, at the display's scale, before the first
//   frame; after that a frame is only where each piece is (one call for all of them), 30 times a second.
// - It's short (3 to 4 seconds) and runs only when Mischief may (MischiefGate): never while a full-screen app, a game
//   or a presentation has the screen, during quiet hours, while you focus, with Windows' animation effects off, or
//   while nobody can see the screen. If any of that starts halfway, it stops at once. One at a time.
// - Nothing runs between celebrations: no timer, and the pieces' windows are taken down after each.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../core/mischief.dart';
import '../../platform/displays.dart';
import '../../platform/native_stage.dart';
import 'stage_cast.dart';
import 'stage_sprites.dart';

/// What to celebrate with.
enum CelebrationKind {
  /// A shower of confetti (green tests, a green build, a milestone).
  confetti,

  /// More of it, for longer (graduation: the first milestone).
  bigConfetti,

  /// Fireworks (a streak).
  fireworks,
}

/// The pieces' colours: Mochi's palette, bright on light and dark wallpapers.
const List<Color> celebrationColors = [
  Color(0xFFFF6B6B),
  Color(0xFFFFC94D),
  Color(0xFF3DDC97),
  Color(0xFF4CC9F0),
  Color(0xFFB388FF),
  Color(0xFFFF8FB8),
];

/// One piece of confetti, in logical pixels on its display.
@immutable
class ConfettiPiece {
  const ConfettiPiece({
    required this.x,
    required this.startY,
    required this.speed,
    required this.sway,
    required this.swaySpeed,
    required this.phase,
    required this.tumble,
    required this.shape,
    required this.color,
  });

  final double x;
  final double startY;
  final double speed;
  final double sway;
  final double swaySpeed;
  final double phase;

  /// Steps of the tumble a second.
  final double tumble;
  final int shape;
  final int color;

  /// Where the piece is [t] seconds in, and which step of its tumble shows.
  (double, double, int) at(double t) {
    final y = startY + speed * t + 18 * t * t;
    final x = this.x + sway * math.sin(swaySpeed * t + phase);
    final step = ((tumble * t + phase * 3).floor() % StageCelebrations.tumbleSteps + StageCelebrations.tumbleSteps) % StageCelebrations.tumbleSteps;
    return (x, y, step);
  }
}

/// One burst of fireworks: a rocket up from the bottom, then sparks every way, falling and fading.
@immutable
class FireworkBurst {
  const FireworkBurst({required this.start, required this.x, required this.y, required this.color, required this.sparks, required this.speeds});

  /// Seconds after the show starts that the rocket goes up.
  final double start;

  /// Where it bursts (logical pixels on its display).
  final double x;
  final double y;
  final int color;
  final int sparks;
  final List<double> speeds;

  static const double rise = 0.55;
  static const double life = 1.35;

  double get end => start + rise + life;
}

class StageCelebrations {
  StageCelebrations({
    required this.stage,
    required this.cast,
    required this.gate,
    required this.displays,
    required this.cursor,
    double Function()? clock,
    math.Random? random,
    this.frameInterval = const Duration(milliseconds: 33),
  }) : sprites = StageSprites(stage, budget: 4 << 20),
       _clock = clock ?? _monotonic(),
       _random = random ?? math.Random();

  final NativeStage stage;
  final StageCast cast;
  final MischiefGate gate;
  final Displays displays;

  /// Where the pointer is (physical pixels), to celebrate on the display you're on.
  final (int, int)? Function() cursor;
  final StageSprites sprites;
  final double Function() _clock;
  final math.Random _random;
  final Duration frameInterval;

  static double Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds / 1e6;
  }

  /// Steps in a piece of confetti's tumble, and its shapes.
  static const int tumbleSteps = 6;
  static const int shapes = 2;

  /// How long each kind lasts (seconds), the last part fading.
  static double length(CelebrationKind kind) => switch (kind) {
    CelebrationKind.confetti => 3.4,
    CelebrationKind.bigConfetti => 4.2,
    CelebrationKind.fireworks => 3.0,
  };

  CelebrationKind? _kind;
  DisplayArea? _display;
  double _start = 0;
  List<ConfettiPiece> _confetti = const [];
  List<FireworkBurst> _bursts = const [];
  final List<int> _actors = [];
  Timer? _frames;
  int _token = 0;

  /// Frames drawn in the last celebration (tests, the perf meter).
  int frames = 0;

  /// What's playing (null: nothing).
  CelebrationKind? get playing => _kind;
  bool get running => _kind != null;

  /// The frame timer runs (only while a celebration plays).
  bool get ticking => _frames != null;

  /// Its pictures are ready and it's playing.
  bool get started => _ready;

  /// Celebrates with [kind] on the display you're on, if Mischief may now ([preview]: you asked for it in Settings, so
  /// only the screen has to be free: someone can see it and no full-screen app has it). False if it didn't start (one
  /// is already playing, or it may not).
  bool celebrate(CelebrationKind kind, {bool preview = false}) {
    if (running) return false;
    final why = gate.why(MischiefExtra.celebrations);
    final allowed = preview
        ? !{MischiefPause.unsupported, MischiefPause.unseen, MischiefPause.fullScreen}.contains(why)
        : why == null;
    if (!allowed) return false;
    final display = _displayNow();
    if (display == null) return false;
    _kind = kind;
    _display = display;
    final token = ++_token;
    frames = 0;
    final size = Size(display.monitor.width / display.scale, display.monitor.height / display.scale);
    if (kind == CelebrationKind.fireworks) {
      _bursts = _plan(size);
      _confetti = const [];
    } else {
      _confetti = _scatter(size, big: kind == CelebrationKind.bigConfetti);
      _bursts = const [];
    }
    _actors
      ..clear()
      ..addAll([for (var i = 0; i < _pieces; i++) stage.newActor()]);
    gate.addListener(_gateChanged);
    _ready = false;
    // The frames start now; the show starts once its pictures are ready (a frame or two later).
    _frames = Timer.periodic(frameInterval, (_) => _frame());
    unawaited(
      sprites.prepare(_recipes(kind, display.scale)).then((_) {
        if (token != _token || !running) return;
        _ready = true;
        _start = _clock();
      }),
    );
    return true;
  }

  /// The pictures are ready and the show has started.
  bool _ready = false;
  static const double _waitAtMost = 3;
  double? _asked;

  /// How many actors this celebration has.
  int get _pieces => _kind == CelebrationKind.fireworks ? _bursts.fold(0, (sum, burst) => sum + burst.sparks + 1) : _confetti.length;

  /// The display the pointer is on (else the main one).
  DisplayArea? _displayNow() {
    final list = displays.list();
    if (list.isEmpty) return null;
    final at = cursor();
    if (at != null) {
      for (final display in list) {
        if (display.monitor.contains(at.$1, at.$2)) return display;
      }
    }
    return PetPlacing.primaryOf(list);
  }

  List<ConfettiPiece> _scatter(Size size, {required bool big}) {
    final count = ((size.width / 1920 * (big ? 84 : 56)).round()).clamp(big ? 40 : 28, big ? 120 : 84);
    return [
      for (var i = 0; i < count; i++)
        ConfettiPiece(
          x: _random.nextDouble() * size.width,
          startY: -12 - _random.nextDouble() * size.height * (big ? 0.55 : 0.4),
          speed: size.height * (0.24 + 0.16 * _random.nextDouble()),
          sway: 10 + 30 * _random.nextDouble(),
          swaySpeed: 1.6 + 2.2 * _random.nextDouble(),
          phase: _random.nextDouble() * math.pi * 2,
          tumble: 6 + 8 * _random.nextDouble(),
          shape: _random.nextInt(shapes),
          color: _random.nextInt(celebrationColors.length),
        ),
    ];
  }

  List<FireworkBurst> _plan(Size size) => [
    for (var i = 0; i < 3; i++)
      FireworkBurst(
        start: i * 0.45,
        x: size.width * (0.22 + 0.28 * i + 0.08 * (_random.nextDouble() - 0.5)),
        y: size.height * (0.22 + 0.16 * _random.nextDouble()),
        color: (i * 2 + _random.nextInt(2)) % celebrationColors.length,
        sparks: 14,
        speeds: [for (var s = 0; s < 14; s++) 150 + 110 * _random.nextDouble()],
      ),
  ];

  static String confettiKey(int shape, int color, int step) => 'confetti $shape $color $step';
  static String sparkKey(int color, int size) => 'spark $color $size';

  /// The pictures this kind needs at [ratio].
  Map<String, SpriteRecipe> _recipes(CelebrationKind kind, double ratio) {
    sprites.use('celebration|$ratio');
    if (kind == CelebrationKind.fireworks) {
      return {
        for (var color = 0; color < celebrationColors.length; color++)
          for (var size = 0; size < 3; size++)
            sparkKey(color, size): SpriteRecipe(
              bounds: const Rect.fromLTRB(-12, -12, 12, 12),
              ratio: ratio,
              paint: (canvas) => CelebrationPieces.spark(canvas, celebrationColors[color], size),
            ),
      };
    }
    return {
      for (var shape = 0; shape < shapes; shape++)
        for (var color = 0; color < celebrationColors.length; color++)
          for (var step = 0; step < tumbleSteps; step++)
            confettiKey(shape, color, step): SpriteRecipe(
              bounds: const Rect.fromLTRB(-12, -12, 12, 12),
              ratio: ratio,
              paint: (canvas) => CelebrationPieces.confetti(canvas, celebrationColors[color], shape, step),
            ),
    };
  }

  void _frame() {
    final kind = _kind;
    final display = _display;
    if (kind == null || display == null) return stop();
    if (!_ready) {
      // Still drawing its pictures: wait (a few seconds at most).
      final asked = _asked ??= _clock();
      if (_clock() - asked > _waitAtMost) stop();
      return;
    }
    final t = _clock() - _start;
    final total = length(kind);
    if (t >= total) return stop();
    frames++;
    final fade = (total - t) < 0.7 ? ((total - t) / 0.7).clamp(0.0, 1.0) : 1.0;
    final scale = display.scale;
    final ox = display.monitor.left, oy = display.monitor.top;
    final height = display.monitor.height / scale;
    void place(int actor, String key, double x, double y, double alpha) {
      final sprite = sprites.lookup(key);
      if (sprite == null || y < -10 || y > height + 10 || alpha <= 0.01) {
        cast.hide(actor);
        return;
      }
      cast.place(sprite.at(actor, ox + (x * scale).round(), oy + (y * scale).round(), alpha: (alpha * 255).round(), clickThrough: true));
    }

    if (kind == CelebrationKind.fireworks) {
      var a = 0;
      for (final burst in _bursts) {
        final local = t - burst.start;
        // The rocket.
        final rocket = _actors[a++];
        if (local >= 0 && local < FireworkBurst.rise) {
          final u = local / FireworkBurst.rise;
          final eased = 1 - (1 - u) * (1 - u);
          place(rocket, sparkKey(1, 2), burst.x, height + 10 - (height + 10 - burst.y) * eased, 1);
        } else {
          cast.hide(rocket);
        }
        // The sparks.
        final since = local - FireworkBurst.rise;
        for (var s = 0; s < burst.sparks; s++) {
          final actor = _actors[a++];
          if (since < 0 || since >= FireworkBurst.life) {
            cast.hide(actor);
            continue;
          }
          final angle = s / burst.sparks * math.pi * 2;
          // Out fast and slowing (drag), then falling.
          final travel = burst.speeds[s] * (1 - math.exp(-2.2 * since)) / 2.2;
          final x = burst.x + math.cos(angle) * travel;
          final y = burst.y + math.sin(angle) * travel + 70 * since * since;
          final life = since / FireworkBurst.life;
          final size = life < 0.35 ? 0 : (life < 0.7 ? 1 : 2);
          place(actor, sparkKey(burst.color, size), x, y, (1 - math.max(0.0, life - 0.45) / 0.55) * fade);
        }
      }
    } else {
      for (var i = 0; i < _confetti.length; i++) {
        final piece = _confetti[i];
        final (x, y, step) = piece.at(t);
        place(_actors[i], confettiKey(piece.shape, piece.color, step), x, y, fade);
      }
    }
    cast.flush();
  }

  void _gateChanged() {
    final why = gate.why(MischiefExtra.celebrations);
    // A full-screen app, the screen going off, quiet hours…: it stops at once (a preview keeps going through the rest).
    if (why == MischiefPause.unseen || why == MischiefPause.fullScreen || why == MischiefPause.off || why == MischiefPause.extraOff) stop();
  }

  /// Stops what's playing and takes its pieces down.
  void stop() {
    _frames?.cancel();
    _frames = null;
    if (_kind == null) return;
    _kind = null;
    _display = null;
    _ready = false;
    _asked = null;
    _token++;
    gate.removeListener(_gateChanged);
    cast.remove(List.of(_actors));
    _actors.clear();
  }

  void dispose() {
    stop();
    sprites.dispose();
  }
}

/// The pieces' art, around the origin (logical pixels).
abstract final class CelebrationPieces {
  /// A piece of confetti: a ribbon (0) or a square (1), [step] of its tumble (it turns and shows its edge).
  static void confetti(Canvas canvas, Color color, int shape, int step) {
    final turn = step / StageCelebrations.tumbleSteps;
    final squash = math.max(0.22, math.cos(turn * math.pi).abs());
    canvas
      ..save()
      ..rotate(turn * math.pi * 0.9 + (shape == 0 ? 0.4 : 0))
      ..scale(squash, 1);
    final face = Paint()..color = Color.lerp(color, const Color(0xFF000000), (1 - squash) * 0.25)!;
    final rect = shape == 0 ? const Rect.fromLTRB(-3.4, -8.6, 3.4, 8.6) : const Rect.fromLTRB(-5.6, -5.6, 5.6, 5.6);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(1.6)), face);
    // A soft highlight along one edge, so it reads as paper catching the light.
    final light = Paint()..color = const Color(0x66FFFFFF);
    canvas
      ..drawRect(Rect.fromLTRB(rect.left, rect.top, rect.left + rect.width * 0.35, rect.bottom), light)
      ..restore();
  }

  /// A spark of a firework: a bright core with a glow, smaller as it burns out ([size] 0 big, 2 small).
  static void spark(Canvas canvas, Color color, int size) {
    final radius = switch (size) {
      0 => 4.6,
      1 => 3.4,
      _ => 2.3,
    };
    canvas
      ..drawCircle(Offset.zero, radius * 2.2, Paint()..color = color.withValues(alpha: 0.28))
      ..drawCircle(Offset.zero, radius * 1.3, Paint()..color = color.withValues(alpha: 0.6))
      ..drawCircle(Offset.zero, radius * 0.75, Paint()..color = Color.lerp(color, const Color(0xFFFFFFFF), 0.7)!);
  }
}
