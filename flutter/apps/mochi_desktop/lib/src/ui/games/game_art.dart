// The games' drawing (Sprint 2 W14), ported line by line from the Mac: the picnic field of Catch the Treats
// (Sources/App/Features/Games/CatchGameView.swift, CatchFieldRenderer), its treats (FeatureArt.drawTreat) and the
// rock-paper-scissors stage (RPSGameView.swift, RPSStageRenderer). Each is drawn in the Mac's own size (528 × 372 and
// 528 × 250 points) and scaled to the space it gets, so it looks the same at any window size. Mochi and Patch are
// mochi_art's.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/rendering.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_ui/mochi_ui.dart' show mochiFontFamily;
import 'package:mochi_world/mochi_world.dart' as w show CatchGame, CatchSplash, PoseContext, RPSRound, RPSStage, RPSChoiceText, TreatKind;

import '../../core/games.dart';

/// Short labels drawn into the games' pictures (in Nunito, the app's rounded type), laid out once and reused.
abstract final class ArtLabel {
  static final Map<String, TextPainter> _cache = {};

  static TextPainter _painter(String text, double size, FontWeight weight, Color color, bool tabular) {
    final key = '$text|$size|${weight.value}|${color.toARGB32()}|$tabular';
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_cache.length > 96) {
      for (final painter in _cache.values) {
        painter.dispose();
      }
      _cache.clear();
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: mochiFontFamily,
          fontFamilyFallback: const ['Segoe UI Emoji', 'Segoe UI', 'Apple Color Emoji', 'sans-serif'],
          fontSize: size,
          fontWeight: weight,
          color: color,
          height: 1.15,
          fontFeatures: tabular ? const [ui.FontFeature.tabularFigures()] : null,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return _cache[key] = painter;
  }

  /// [text] at [at] in [g]'s space: [anchor] says which point of the text sits there (its centre by default), with an
  /// [outline] around the letters if given (the Mac's `drawCenteredText`).
  static void draw(
    GContext g,
    String text,
    Offset at,
    double size, {
    FontWeight weight = FontWeight.w800,
    required Color color,
    Alignment anchor = Alignment.center,
    Color? outline,
    bool tabular = false,
  }) {
    if (g.opacity <= 0) return;
    void paint(Color tint, Offset offset) {
      final painter = _painter(text, size, weight, g.opacity >= 1 ? tint : tint.fade(g.opacity), tabular);
      final origin = at + offset - Offset((anchor.x + 1) / 2 * painter.width, (anchor.y + 1) / 2 * painter.height);
      g.raw((canvas) => painter.paint(canvas, origin));
    }

    if (outline != null) {
      for (final (dx, dy) in const [(-1.2, 0.0), (1.2, 0.0), (0.0, -1.2), (0.0, 1.2)]) {
        paint(outline, Offset(dx, dy));
      }
    }
    paint(color, Offset.zero);
  }
}

/// Small drawing helpers shared by the games (the Mac's FeatureArt).
abstract final class FeatureArt {
  /// Patch standing on his own: no laptop or desk.
  static CompanionPose standalone(CompanionPose pose) {
    final copy = pose.copy();
    copy.laptop
      ..visible = false
      ..openness = 0
      ..screen = LaptopScreen.off;
    copy.reach = 0;
    return copy;
  }

  static void drawCompanion(CompanionPose pose, GContext g, Offset at, double scale, {Accessory? accessory, bool dark = false, double time = 0}) =>
      CompanionRenderer.draw(standalone(pose), g, at, scale, accessory: accessory, dark: dark, time: time, workstation: false);

  /// A treat from the game, centred on [at] (about [size] points across).
  static void drawTreat(w.TreatKind kind, GContext g, Offset at, double size, double rotation, double time) {
    final t = g.copy()..translateBy(at.dx, at.dy);
    switch (kind) {
      case w.TreatKind.cookie:
        ItemRenderer.cookie(t, size, spin: rotation);
      case w.TreatKind.fish:
        t
          ..rotate(0.35 * math.sin(rotation))
          ..scaleBy(size / 20, size / 20);
        ItemRenderer.fish(t, 0);
      case w.TreatKind.berry:
        t.rotate(0.4 * math.sin(rotation * 0.7));
        ItemRenderer.berry(t, size / 13);
      case w.TreatKind.golden:
        // A warm glow and two twinkles around a golden cookie.
        final pulse = 0.85 + 0.15 * math.sin(time * 6);
        t.fillRadial(
          Shapes.ellipse(Offset.zero, size * 2.3 * pulse, size * 2.3 * pulse),
          [hex(0xFFE27A).fade(0.75), hex(0xFFE27A).fade(0)],
          Offset.zero,
          size * 0.2,
          size * 1.15 * pulse,
        );
        final cookie = Shapes.ellipse(Offset.zero, size * 1.05, size * 1.05);
        t.fillRadial(cookie, [hex(0xFFF1A8), hex(0xF5B83D)], Offset(-size * 0.15, -size * 0.18), 0, size * 0.6);
        t.stroke(cookie, hex(0xC98A1E), math.max(1, size / 11));
        t.fill(Shapes.star(Offset.zero, size * 0.28), white.fade(0.9));
        for (var index = 0; index < 2; index++) {
          final angle = time * 2.2 + index * math.pi;
          final p = Offset(math.cos(angle) * size * 0.85, math.sin(angle) * size * 0.85);
          t.fill(Shapes.sparkle(p, size * 0.22 * (0.6 + 0.4 * math.sin(time * 4 + index).abs())), white);
        }
    }
  }
}

/// Everything the field needs besides the game: how Mochi looks and moves.
class GameLook {
  const GameLook({
    required this.color,
    this.petAccessory,
    this.companionAccessory,
    this.reducedMotion = false,
    this.seed = 1,
    this.dark = false,
  });

  final PetColor color;
  final Accessory? petAccessory;
  final Accessory? companionAccessory;
  final bool reducedMotion;
  final int seed;
  final bool dark;

  w.PoseContext pet(double time) => w.PoseContext(time: time, reducedMotion: reducedMotion, seed: seed);
  w.PoseContext companion(double time) => w.PoseContext(time: time, reducedMotion: reducedMotion, seed: seed + 0x5EED);

  @override
  bool operator ==(Object other) =>
      other is GameLook &&
      other.color == color &&
      other.petAccessory == petAccessory &&
      other.companionAccessory == companionAccessory &&
      other.reducedMotion == reducedMotion &&
      other.seed == seed &&
      other.dark == dark;

  @override
  int get hashCode => Object.hash(color, petAccessory, companionAccessory, reducedMotion, seed, dark);
}

/// The picnic field, the treats, Mochi and the score (the Mac's CatchFieldRenderer), in the Mac's 528 × 372 points.
class CatchFieldPainter extends CustomPainter {
  CatchFieldPainter({required this.session, required this.clock, required this.look, required this.best, required this.showHUD})
    : super(repaint: clock);

  /// The game being drawn (read at paint time: a new game swaps it).
  final CatchSession Function() session;

  /// The world's clock (seconds): every change repaints the field.
  final ValueNotifier<double> clock;
  final GameLook look;
  final int best;
  final bool showHUD;

  static const Size design = Size(528, 372);
  static const double inset = 26;
  static const double top = 18;
  static const double grass = 40;

  /// The pointer's x (in the field's own width) in field units.
  static double fieldX(double x, double width) {
    final k = width / design.width;
    return (x / k - inset) / (design.width - 2 * inset);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final k = size.width / design.width;
    canvas.scale(k, k);
    draw(GContext(canvas), session(), clock.value);
    canvas.restore();
  }

  void draw(GContext g, CatchSession session, double time) {
    const size = design;
    final game = session.game;
    final dark = look.dark;
    final floor = size.height - grass;
    Offset point(double x, double y) => Offset(inset + x * (size.width - 2 * inset), floor - y * (floor - top));
    drawBackdrop(g, size, floor, dark, time);

    // Treats that landed rest on the grass for a moment, then fade.
    for (final splash in game.splashes.where((s) => s.points == 0)) {
      final age = game.time - splash.at;
      final faded = g.copy()..opacity = math.max(0, 1 - age / w.CatchGame.splashLife);
      final p = point(splash.x, 0);
      FeatureArt.drawTreat(splash.kind, faded, Offset(p.dx, p.dy - 6), 18, 1.4, time);
      final dust = g.copy()..translateBy(p.dx, p.dy);
      EffectRenderer.draw(Effect(EffectKind.dust, scale: 1.2, phase: math.min(1, age / 0.5)), dust, unitX: 1, unitY: 1, dark: dark);
    }

    // Mochi.
    final pose = game.petPose(look.pet(time));
    final pet = point(game.petX, 0);
    PetRenderer.draw(pose, g, Offset(pet.dx, floor + 2), 1.08, PetPalette(look.color), accessory: look.petAccessory, dark: dark);

    for (final treat in game.treats) {
      final p = point(treat.x, treat.y);
      FeatureArt.drawTreat(treat.kind, g, p, treat.kind == w.TreatKind.golden ? 22 : 21, treat.rotation, time);
    }

    // Catches: a pop and the points floating up.
    for (final splash in game.splashes.where((s) => s.points > 0)) {
      _catch(g, splash, game.time - splash.at, point(splash.x, splash.y), dark);
    }

    if (showHUD) drawHUD(g, game, size, best, session.fasterAt);
  }

  static void _catch(GContext g, w.CatchSplash splash, double age, Offset p, bool dark) {
    final pop = g.copy()..translateBy(p.dx, p.dy);
    final golden = splash.kind == w.TreatKind.golden;
    EffectRenderer.draw(
      Effect(
        golden ? EffectKind.heartPop : EffectKind.pop,
        scale: 1.3,
        variant: splash.kind == w.TreatKind.berry ? 0 : 2,
        phase: math.min(1, age / 0.5),
      ),
      pop,
      unitX: 1,
      unitY: 1,
      dark: dark,
    );
    final label = g.copy()..opacity = math.max(0, 1 - age / w.CatchGame.splashLife);
    ArtLabel.draw(
      label,
      '+${splash.points}',
      Offset(p.dx, p.dy - 26 - age * 34),
      golden ? 20 : 16,
      color: golden ? hex(0xF5A623) : hex(0xE2557A),
      outline: white,
    );
  }

  static void drawBackdrop(GContext g, Size size, double floor, bool dark, double time) {
    final rect = Offset.zero & size;
    final sky = dark ? [hex(0x2E2F63), hex(0x6A4E86)] : [hex(0xBFE4FF), hex(0xFFE7D1)];
    g.fillLinear(Shapes.rect(rect), sky, Offset.zero, Offset(0, floor));

    // Sun (or moon) with a soft glow.
    final sun = Offset(size.width - 74, 62);
    final glow = dark ? hex(0xFFF3C4) : hex(0xFFE08A);
    g.fillRadial(Shapes.ellipse(sun, 120, 120), [glow.fade(0.55), glow.fade(0)], sun, 10, 60);
    g.fill(Shapes.ellipse(sun, 38, 38), dark ? hex(0xFFF6DC) : hex(0xFFD45E));
    if (dark) {
      for (var index = 0; index < 14; index++) {
        final x = Ease.hash(index, 11) * size.width;
        final y = Ease.hash(index, 23) * floor * 0.55;
        final twinkle = 0.45 + 0.4 * math.sin(time * 1.6 + index);
        g.fill(Shapes.sparkle(Offset(x, y), 2.6), white.fade(twinkle));
      }
    }

    // Drifting clouds.
    for (var index = 0; index < 3; index++) {
      final speed = 6.0 + index * 3;
      final span = size.width + 160;
      final x = (index * 210 + time * speed) % span - 80;
      final y = 48.0 + index * 38;
      cloud(g, Offset(x, y), 0.8 + 0.2 * (index % 2), white.fade(dark ? 0.16 : 0.85));
    }

    // Rolling hills behind the picnic.
    hill(g, size, floor, 92, 0.2, dark ? hex(0x3C5B67) : hex(0xC8EBC0));
    hill(g, size, floor, 58, 1.7, dark ? hex(0x2F4D50) : hex(0xA9DE9E));

    // Grass, with a picnic blanket to run on.
    g.fill(Shapes.rect(Rect.fromLTWH(0, floor - 4, size.width, size.height - floor + 4)), dark ? hex(0x3F6B4E) : hex(0x8ED17E));
    final blanket = Rect.fromLTWH(10, floor + 6, size.width - 20, size.height - floor - 12);
    final cloth = g.copy()..clip(Shapes.roundedRect(blanket, 7));
    cloth.fill(Shapes.rect(blanket), dark ? hex(0xD9C9E8) : hex(0xFFF6F2));
    final check = dark ? hex(0xB07BC9).fade(0.45) : hex(0xFF8FA3).fade(0.45);
    for (var x = blanket.left; x < blanket.right; x += 18) {
      cloth.fill(Shapes.rect(Rect.fromLTWH(x, blanket.top, 9, blanket.height)), check);
    }
    for (var y = blanket.top; y < blanket.bottom; y += 12) {
      cloth.fill(Shapes.rect(Rect.fromLTWH(blanket.left, y, blanket.width, 6)), check);
    }
    g.stroke(Shapes.roundedRect(blanket, 7), dark ? hex(0x9C7AB5) : hex(0xF29BAE), 1.2);
    // Tufts along the edge of the grass.
    for (var index = 0; index < 26; index++) {
      final tx = index * size.width / 25 + Ease.hash(index, 5) * 8;
      final tuft = Path()
        ..moveTo(tx - 3, floor - 2)
        ..lineTo(tx - 1, floor - 8)
        ..moveTo(tx + 1, floor - 2)
        ..lineTo(tx + 3, floor - 9);
      g.stroke(tuft, dark ? hex(0x5C8E66) : hex(0x6DBA63), 1.6);
    }
  }

  static void cloud(GContext g, Offset p, double s, Color color) {
    final path = Path();
    for (final (dx, dy, r) in const [(-22.0, 4.0, 15.0), (0.0, -6.0, 20.0), (22.0, 3.0, 15.0), (6.0, 8.0, 14.0)]) {
      path.addOval(Rect.fromLTWH(p.dx + (dx - r) * s, p.dy + (dy - r) * s, 2 * r * s, 2 * r * s));
    }
    g.fill(path, color);
  }

  static void hill(GContext g, Size size, double base, double height, double phase, Color color) {
    final path = Path()..moveTo(0, base);
    const steps = 48;
    for (var index = 0; index <= steps; index++) {
      final u = index / steps;
      final y = base - height * (0.55 + 0.25 * math.sin(u * 5.2 + phase) + 0.2 * math.sin(u * 11.3 + phase * 2));
      path.lineTo(u * size.width, y);
    }
    path
      ..lineTo(size.width, base)
      ..close();
    g.fill(path, color);
  }

  static void drawHUD(GContext g, w.CatchGame game, Size size, int best, double? fasterAt) {
    final ink = hex(0x4A3B5C);
    // Score pill.
    g.fill(Shapes.roundedRect(Rect.fromLTWH(12, 12, 112, game.combo >= 2 ? 50 : 36), 12), white.fade(0.78));
    ArtLabel.draw(g, 'SCORE', const Offset(24, 19), 9, weight: FontWeight.w900, color: ink.fade(0.6), anchor: Alignment.topLeft);
    ArtLabel.draw(g, '${game.score}', const Offset(112, 30), 20, weight: FontWeight.w900, color: ink, anchor: Alignment.centerRight, tabular: true);
    if (game.combo >= 2) {
      final multiplier = w.CatchGame.multiplier(game.combo);
      final text = multiplier > 1 ? '×$multiplier · ${game.combo} in a row' : '${game.combo} in a row';
      ArtLabel.draw(g, text, const Offset(24, 47), 10.5, weight: FontWeight.w700, color: hex(0xE2557A), anchor: Alignment.centerLeft);
    }

    // Lives as hearts.
    final lives = w.CatchGame.maxMisses - game.misses;
    g.fill(Shapes.roundedRect(Rect.fromLTWH(size.width - 92, 12, 80, 30), 12), white.fade(0.78));
    for (var index = 0; index < w.CatchGame.maxMisses; index++) {
      final center = Offset(size.width - 74 + index * 22, 27);
      final heart = Shapes.heart(center, 15);
      if (index < lives) {
        g.fill(heart, hex(0xFF6F91));
        g.fill(Shapes.ellipse(Offset(center.dx - 3, center.dy - 3), 3.4, 2.4), white.fade(0.6));
      } else {
        g.stroke(heart, ink.fade(0.28), 1.4);
      }
    }

    if (best > 0) {
      ArtLabel.draw(g, 'Best $best', Offset(size.width - 52, 52), 10.5, weight: FontWeight.w700, color: ink.fade(0.55), tabular: true);
    }

    if (fasterAt != null && game.time - fasterAt < 1.4) {
      final age = game.time - fasterAt;
      final scale = 1 + 0.25 * (1 - Ease.outBack(Ease.segment(age, 0, 0.35)));
      final note = g.copy()
        ..opacity = math.min(1, age / 0.15) * (1 - Ease.segment(age, 1.0, 1.4))
        ..translateBy(size.width / 2, 64)
        ..scaleBy(scale, scale);
      ArtLabel.draw(note, 'Faster!', Offset.zero, 24, weight: FontWeight.w900, color: hex(0xFF8A5C), outline: white);
    }
  }

  @override
  bool shouldRepaint(CatchFieldPainter old) =>
      old.session != session || old.clock != clock || old.look != look || old.best != best || old.showHUD != showHUD;
}

/// The rock-paper-scissors stage (the Mac's RPSStageRenderer): Mochi on the left, Patch on the right, your hand in the
/// middle (just Mochi and you when Patch never shows), in the Mac's 528 × 250 points.
class RPSStagePainter extends CustomPainter {
  RPSStagePainter({required this.games, required this.clock, required this.look}) : super(repaint: clock);

  final DesktopGames games;
  final ValueNotifier<double> clock;
  final GameLook look;

  static const Size design = Size(528, 250);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final k = size.width / design.width;
    canvas.scale(k, k);
    final now = clock.value;
    final started = games.roundStartedAt;
    draw(GContext(canvas), now: now, round: games.round, elapsed: started == null ? null : now - started, withCompanion: games.match.withCompanion);
    canvas.restore();
  }

  void draw(GContext g, {required double now, required w.RPSRound? round, required double? elapsed, required bool withCompanion}) {
    const size = design;
    final dark = look.dark;
    final colors = dark ? [hex(0x33305C), hex(0x52406E)] : [hex(0xFFF1E4), hex(0xEDE4FF)];
    g.fillLinear(Shapes.rect(Offset.zero & size), colors, Offset.zero, Offset(size.width, size.height));
    // Soft spotlights for the two players.
    final floor = size.height - 30;
    final petX = w.RPSStage.petX(withCompanion);
    for (final (x, tint) in [(petX, hex(0xFFC9A8)), if (withCompanion) (w.RPSStage.companionX, hex(0xB8E8DA))]) {
      final center = Offset(size.width * x, floor);
      g.fillRadial(Shapes.ellipse(center, 170, 44), [tint.fade(dark ? 0.35 : 0.7), tint.fade(0)], center, 4, 85);
    }
    // Confetti dots in the background.
    for (var index = 0; index < 18; index++) {
      final x = Ease.hash(index, 3) * size.width;
      final y = Ease.hash(index, 9) * (floor - 40) + 10;
      final color = ConfettiPalette.colors[index % ConfettiPalette.colors.length];
      g.fill(Shapes.ellipse(Offset(x, y), 5, 5), color.fade(dark ? 0.35 : 0.45));
    }

    final petPose = w.RPSStage.petPose(round, elapsed, look.pet(now));
    PetRenderer.draw(petPose, g, Offset(size.width * petX, floor), 1.55, PetPalette(look.color), accessory: look.petAccessory, dark: dark);
    if (withCompanion) {
      final pose = w.RPSStage.companionPose(round, elapsed, look.companion(now));
      FeatureArt.drawCompanion(pose, g, Offset(size.width * w.RPSStage.companionX, floor + 6), 1.32, accessory: look.companionAccessory, dark: dark, time: now);
    }
    drawPlayerHand(g, size, size.width * w.RPSStage.handX(withCompanion), round, elapsed, dark, now, look.reducedMotion);
    drawChant(g, size, elapsed);
    if (round != null && elapsed != null && elapsed >= w.RPSStage.shake + 0.15) {
      final age = elapsed - w.RPSStage.shake - 0.15;
      badge(g, -round.vsPet, Offset(size.width * petX, 26), age);
      if (round.vsCompanion case final outcome?) badge(g, -outcome, Offset(size.width * w.RPSStage.companionX, 26), age);
    }
  }

  /// Your hand: a fist that bobs with the chant, then your pick.
  static void drawPlayerHand(GContext g, Size size, double centerX, w.RPSRound? round, double? elapsed, bool dark, double time, bool calm) {
    final base = Offset(centerX, size.height - 74);
    var emoji = '✊';
    var bob = 0.0;
    var pop = 1.0;
    var label = 'You';
    if (round != null && elapsed != null) {
      if (elapsed < w.RPSStage.shake) {
        bob = calm ? 0 : -math.sin(math.pi * elapsed / 0.5).abs() * 12;
      } else {
        emoji = round.player.emoji;
        pop = calm ? 1 : 1 + 0.3 * (1 - Ease.outBack(Ease.segment(elapsed - w.RPSStage.shake, 0, 0.3)));
        label = round.player.title;
      }
    } else if (!calm) {
      bob = math.sin(time * 2) * 2;
    }
    final center = Offset(base.dx, base.dy + bob);
    g.fill(Shapes.ellipse(Offset(base.dx, size.height - 30), 54, 12), black.fade(dark ? 0.25 : 0.08));
    final disc = Shapes.ellipse(center, 66 * pop, 66 * pop);
    g.fill(disc, dark ? hex(0x4A4472) : white);
    g.stroke(disc, dark ? hex(0x8C7FC0) : hex(0xE5DAF5), 2);
    final hand = g.copy()
      ..translateBy(center.dx, center.dy)
      ..scaleBy(pop, pop);
    ArtLabel.draw(hand, emoji, Offset.zero, 32, weight: FontWeight.w400, color: black);
    ArtLabel.draw(g, label, Offset(base.dx, size.height - 18), 11, weight: FontWeight.w700, color: dark ? white.fade(0.8) : hex(0x6A5C7A));
  }

  /// "Rock…", "Paper…", "Scissors…", "Shoot!" over the shake.
  static void drawChant(GContext g, Size size, double? elapsed) {
    if (elapsed == null) return;
    final word = w.RPSStage.chant(elapsed);
    if (word == null) return;
    final index = math.min(3, (elapsed / 0.5).floor());
    final local = elapsed - index * 0.5;
    final scale = 1 + 0.35 * (1 - Ease.outBack(Ease.segment(local, 0, 0.2)));
    final text = g.copy()
      ..opacity = index == 3 ? 1 - Ease.segment(local, 0.4, 0.6) : 1
      ..translateBy(size.width / 2, 40)
      ..scaleBy(scale, scale);
    ArtLabel.draw(text, word, Offset.zero, index == 3 ? 26 : 20, weight: FontWeight.w900, color: index == 3 ? hex(0xFF6F91) : hex(0x7A68C9), outline: white);
  }

  /// "Won!" above a character that beat you, "Lost" when you beat it, "Draw" otherwise.
  static void badge(GContext g, int outcome, Offset at, double age) {
    final tint = outcome > 0 ? hex(0xFF8A5C) : (outcome < 0 ? hex(0x8C84A8) : hex(0x62BDF2));
    final scale = Ease.outBack(Ease.segment(age, 0, 0.25));
    if (scale <= 0) return;
    final b = g.copy()
      ..translateBy(at.dx, at.dy)
      ..scaleBy(scale, scale);
    b.fill(Shapes.roundedRect(const Rect.fromLTWH(-30, -12, 60, 24), 12), tint);
    ArtLabel.draw(b, w.RPSStage.badge(outcome), Offset.zero, 12.5, weight: FontWeight.w900, color: white);
  }

  @override
  bool shouldRepaint(RPSStagePainter old) => old.games != games || old.clock != clock || old.look != look;
}
