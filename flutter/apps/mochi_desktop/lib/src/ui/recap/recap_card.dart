// The recap card (Sprint 2 W16), the Mac's RecapCard and RecapStage (Sources/App/Features/Recap/RecapCardView.swift)
// drawn by the app: 420 × 560 points, always light so a saved picture looks the same everywhere. Mochi and Patch
// present the day at the top (Mochi raises a paw and hops, Patch holds up a trophy for a day with finished turns; both
// rest on a quiet day), then the title, the date and the streak, a tile for each number worth one, a line about the
// day and where the numbers come from. The same painters draw it on screen (only the characters move) and into the
// picture that's saved or copied, at twice the size.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_ui/mochi_ui.dart' show mochiFontFamily;
import 'package:mochi_world/mochi_world.dart' as w;

import '../../platform/image_export.dart';
import '../games/game_art.dart' show FeatureArt;

/// What the card needs besides the numbers: names, looks, how the characters move, and how times and days are
/// written here.
class RecapLook {
  const RecapLook({
    required this.petName,
    required this.companionName,
    this.petColor = PetColor.cream,
    this.petAccessory,
    this.companionAccessory,
    this.showCompanion = true,
    this.reducedMotion = false,
    this.seed = 1,
    required this.formatTime,
    this.computer = 'PC',
  });

  final String petName;
  final String companionName;
  final PetColor petColor;
  final Accessory? petAccessory;
  final Accessory? companionAccessory;
  final bool showCompanion;
  final bool reducedMotion;
  final int seed;

  /// A short local time ("9:41 AM" or "09:41").
  final String Function(DateTime time) formatTime;

  /// "PC" (the footer's "on this PC").
  final String computer;

  @override
  bool operator ==(Object other) =>
      other is RecapLook &&
      other.petName == petName &&
      other.companionName == companionName &&
      other.petColor == petColor &&
      other.petAccessory == petAccessory &&
      other.companionAccessory == companionAccessory &&
      other.showCompanion == showCompanion &&
      other.reducedMotion == reducedMotion &&
      other.seed == seed;

  @override
  int get hashCode => Object.hash(petName, companionName, petColor, petAccessory, companionAccessory, showCompanion, reducedMotion, seed);
}

/// The words on the card, and how a screen reader hears it.
abstract final class RecapText {
  static const List<String> _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const List<String> _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// "Sunday, 8 November 2026".
  static String date(DateTime day) => '${_weekdays[day.weekday - 1]}, ${day.day} ${_months[day.month - 1]} ${day.year}';

  static String title(w.DailyRecap recap, RecapLook look, DateTime now) =>
      recap.title(now: now, petName: look.petName, companionName: look.companionName, showCompanion: look.showCompanion);

  /// A tile's big number ("9:00 AM–2:30 PM" for the active stretch).
  static String value(w.RecapTile tile, RecapLook look) => switch (tile) {
    w.RecapActiveSpan(:final from, :final to) => '${look.formatTime(from)}–${look.formatTime(to)}',
    _ => tile.value,
  };

  static String footer(w.DailyRecap recap, RecapLook look) => recap.footer(computer: look.computer, formatTime: look.formatTime);

  /// The whole card in words.
  static String spoken(w.DailyRecap recap, RecapLook look, DateTime now) {
    final parts = [
      '${title(recap, look, now)}.',
      '${date(recap.day)}.',
      if (recap.streakText case final streak?) '$streak.',
      if (recap.tiles.isEmpty) recap.quietMessage(now: now, computer: look.computer).replaceAll('\n', ' '),
      for (final tile in recap.tiles) '${value(tile, look)} ${tile.label}${tile.detail == null || tile.detail!.isEmpty ? '' : ', ${tile.detail}'}.',
      recap.summary(petName: look.petName, companionName: look.companionName),
      '${footer(recap, look)}.',
    ];
    return parts.join(' ');
  }
}

/// The card's colours (the Mac's RecapPalette and tiles).
abstract final class RecapPalette {
  static final Color ink = hex(0x41324F);

  static List<Color> background({required bool quiet}) =>
      quiet ? [hex(0xE4E6FF), hex(0xF3E9FF), hex(0xFFF3EC)] : [hex(0xFFE6D6), hex(0xFFF2E8), hex(0xEDE6FF)];

  static (IconData, Color) tile(w.RecapTile tile) => switch (tile) {
    w.RecapTurns() => (Icons.check_rounded, hex(0x4CB782)),
    w.RecapSessions() => (Icons.forum_rounded, hex(0x7B7BEA)),
    w.RecapToolCalls() => (Icons.handyman_rounded, hex(0xF29A4A)),
    w.RecapBuildsAndTests() => (Icons.verified_rounded, hex(0x2FB3A0)),
    w.RecapBouncedBack() => (Icons.u_turn_left_rounded, hex(0xF0718F)),
    w.RecapFocus() => (Icons.bedtime_rounded, hex(0x9C7BEA)),
    w.RecapActiveSpan() => (Icons.schedule_rounded, hex(0x5AA9E6)),
    w.RecapMilestones() => (Icons.flag_rounded, hex(0xE9B33F)),
  };
}

/// Lays out and paints a piece of the card's text.
TextPainter _text(
  String text,
  double size, {
  FontWeight weight = FontWeight.w600,
  required Color color,
  double? maxWidth,
  int? maxLines = 1,
  TextAlign align = TextAlign.left,
  bool tabular = false,
}) => TextPainter(
  text: TextSpan(
    text: text,
    style: TextStyle(
      fontFamily: mochiFontFamily,
      fontFamilyFallback: const ['Segoe UI', 'sans-serif'],
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: 1.2,
      fontFeatures: tabular ? const [ui.FontFeature.tabularFigures()] : null,
    ),
  ),
  textDirection: TextDirection.ltr,
  textAlign: align,
  maxLines: maxLines,
  ellipsis: '…',
)..layout(maxWidth: maxWidth ?? double.infinity);

/// A Material icon as a glyph.
TextPainter _icon(IconData icon, double size, Color color) => TextPainter(
  text: TextSpan(
    text: String.fromCharCode(icon.codePoint),
    style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: size, color: color, height: 1),
  ),
  textDirection: TextDirection.ltr,
)..layout();

/// Text that shrinks to [minScale] to fit [width] before it's cut short (SwiftUI's `minimumScaleFactor`).
TextPainter _fitted(String text, double size, double width, {FontWeight weight = FontWeight.w800, required Color color, double minScale = 0.7}) {
  var painter = _text(text, size, weight: weight, color: color);
  if (painter.width <= width) return painter;
  final scale = math.max(minScale, width / painter.width);
  painter.dispose();
  painter = _text(text, size * scale, weight: weight, color: color, maxWidth: width);
  return painter;
}

/// The still part of the card: everything but the characters.
class RecapCardPainter extends CustomPainter {
  RecapCardPainter({required this.recap, required this.look, required this.now});

  final w.DailyRecap recap;
  final RecapLook look;
  final DateTime now;

  static const Size size = Size(420, 560);
  static const double stageHeight = 164;
  static const double radius = 26;

  static Path shape() => Shapes.roundedRect(Offset.zero & size, radius);

  /// The characters' band at the top of the card.
  static Path stage() => Path.combine(PathOperation.intersect, shape(), Shapes.rect(const Rect.fromLTWH(0, 0, 420, stageHeight)));

  @override
  void paint(Canvas canvas, Size box) {
    canvas.save();
    final k = box.width / size.width;
    canvas.scale(k, k);
    paintCard(canvas, recap, look, now);
    canvas.restore();
  }

  static void paintCard(Canvas canvas, w.DailyRecap recap, RecapLook look, DateTime now) {
    final g = GContext(canvas)..clip(shape());
    final quiet = recap.isQuiet;
    final ink = RecapPalette.ink;
    g.fillLinear(Shapes.rect(Offset.zero & size), RecapPalette.background(quiet: quiet), Offset.zero, Offset(0, size.height));

    // The title, the date and the streak.
    var y = stageHeight + 2;
    final title = _fitted(RecapText.title(recap, look, now), 21, size.width - 40, color: ink);
    title.paint(canvas, Offset((size.width - title.width) / 2, y));
    y += title.height + 5;
    final date = _text(RecapText.date(recap.day), 12, weight: FontWeight.w500, color: ink.fade(0.6));
    final streak = recap.streakText;
    TextPainter? chipText;
    var rowWidth = date.width;
    if (streak != null) {
      chipText = _text(streak, 10.5, weight: FontWeight.w700, color: hex(0xE8663D));
      rowWidth += 8 + chipText.width + 30;
    }
    final rowHeight = math.max(date.height, 20.0);
    var x = (size.width - rowWidth) / 2;
    date.paint(canvas, Offset(x, y + (rowHeight - date.height) / 2));
    if (chipText != null) {
      x += date.width + 8;
      final chip = Rect.fromLTWH(x, y + (rowHeight - 20) / 2, chipText.width + 30, 20);
      g.fill(Shapes.roundedRect(chip, 10), hex(0xFFE3D3));
      final flame = _icon(Icons.local_fire_department_rounded, 12, hex(0xE8663D));
      flame.paint(canvas, Offset(chip.left + 8, chip.center.dy - flame.height / 2));
      chipText.paint(canvas, Offset(chip.left + 22, chip.center.dy - chipText.height / 2));
      flame.dispose();
      chipText.dispose();
    }
    y += rowHeight;
    title.dispose();
    date.dispose();

    // The day in words and where the numbers come from, from the bottom up.
    final footer = _text(RecapText.footer(recap, look), 9.5, weight: FontWeight.w500, color: ink.fade(0.4), maxWidth: size.width - 60);
    final paw = _icon(Icons.pets_rounded, 9, ink.fade(0.4));
    final footerTop = size.height - 12 - footer.height;
    final footerLeft = (size.width - footer.width - paw.width - 5) / 2;
    paw.paint(canvas, Offset(footerLeft, footerTop + (footer.height - paw.height) / 2));
    footer.paint(canvas, Offset(footerLeft + paw.width + 5, footerTop));
    final summary = _text(
      recap.summary(petName: look.petName, companionName: look.companionName),
      13,
      weight: FontWeight.w600,
      color: ink.fade(0.85),
      maxWidth: size.width - 52,
      maxLines: 2,
      align: TextAlign.center,
    );
    final summaryTop = footerTop - 8 - summary.height;
    summary.paint(canvas, Offset((size.width - summary.width) / 2, summaryTop));
    footer.dispose();
    paw.dispose();
    summary.dispose();

    // A tile for each number worth one; a quiet day's note in the middle of the space.
    final tiles = recap.tiles;
    const left = 18.0;
    final width = size.width - 2 * left;
    if (tiles.isEmpty) {
      final message = _text(
        recap.quietMessage(now: now, computer: look.computer),
        13,
        weight: FontWeight.w500,
        color: ink.fade(0.7),
        maxWidth: width - 40,
        maxLines: 4,
        align: TextAlign.center,
      );
      final moon = _icon(Icons.nights_stay_rounded, 30, hex(0x9C8CFF));
      final height = 30 + moon.height + 8 + message.height + 30;
      final top = y + math.max(6, (summaryTop - 6 - y - height) / 2);
      g.fill(Shapes.roundedRect(Rect.fromLTWH(left, top, width, height), 16), white.fade(0.55));
      moon.paint(canvas, Offset((size.width - moon.width) / 2, top + 30));
      message.paint(canvas, Offset((size.width - message.width) / 2, top + 30 + moon.height + 8));
      moon.dispose();
      message.dispose();
      return;
    }
    y += 14;
    const gap = 8.0;
    for (var index = 0; index < tiles.length; index += 2) {
      final pair = index + 1 < tiles.length;
      final tileWidth = pair ? (width - gap) / 2 : width;
      _tile(g, canvas, tiles[index], look, Rect.fromLTWH(left, y, tileWidth, 60));
      if (pair) _tile(g, canvas, tiles[index + 1], look, Rect.fromLTWH(left + tileWidth + gap, y, tileWidth, 60));
      y += 60 + gap;
    }
  }

  static void _tile(GContext g, Canvas canvas, w.RecapTile tile, RecapLook look, Rect rect) {
    final ink = RecapPalette.ink;
    final (icon, tint) = RecapPalette.tile(tile);
    final shape = Shapes.roundedRect(rect, 14);
    g.fill(shape, white.fade(0.72));
    g.stroke(shape, white.fade(0.9), 1);
    final circle = Offset(rect.left + 10 + 16, rect.center.dy);
    g.fillLinear(Shapes.ellipse(circle, 32, 32), [Color.lerp(tint, white, 0.18)!, tint], circle.translate(0, -16), circle.translate(0, 16));
    final glyph = _icon(icon, 15, white);
    glyph.paint(canvas, circle - Offset(glyph.width / 2, glyph.height / 2));
    glyph.dispose();
    final textLeft = rect.left + 10 + 32 + 10;
    final textWidth = rect.right - 10 - textLeft;
    final valueText = RecapText.value(tile, look);
    final value = _fitted(valueText, valueText.length > 7 ? 15 : 19, textWidth, weight: FontWeight.w800, color: ink);
    final label = _text(tile.label, 10.5, weight: FontWeight.w600, color: ink.fade(0.55), maxWidth: textWidth);
    final detailText = tile.detail;
    final detail = detailText == null || detailText.isEmpty
        ? null
        : _text(detailText, 9.5, weight: FontWeight.w700, color: tint, maxWidth: textWidth);
    final height = value.height + label.height + (detail?.height ?? 0);
    var y = rect.center.dy - height / 2;
    value.paint(canvas, Offset(textLeft, y));
    y += value.height;
    label.paint(canvas, Offset(textLeft, y));
    y += label.height;
    detail?.paint(canvas, Offset(textLeft, y));
    value.dispose();
    label.dispose();
    detail?.dispose();
  }

  @override
  bool shouldRepaint(RecapCardPainter old) => old.recap != recap || old.look != look || old.now != now;
}

/// The characters presenting the day, with bunting and confetti (the Mac's RecapStage): the only part of the card that
/// moves on screen.
class RecapStagePainter extends CustomPainter {
  RecapStagePainter({required this.recap, required this.look, this.clock, this.time = 2.2}) : super(repaint: clock);

  final w.DailyRecap recap;
  final RecapLook look;

  /// The animation's clock (seconds), or a still moment ([time]) for a picture.
  final ValueNotifier<double>? clock;
  final double time;

  @override
  void paint(Canvas canvas, Size box) {
    canvas.save();
    final k = box.width / RecapCardPainter.size.width;
    canvas.scale(k, k);
    final g = GContext(canvas)..clip(RecapCardPainter.stage());
    draw(g, recap, look, clock?.value ?? time);
    canvas.restore();
  }

  static void draw(GContext g, w.DailyRecap recap, RecapLook look, double time) {
    const size = Size(420, RecapCardPainter.stageHeight);
    final quiet = recap.isQuiet;
    final reduced = look.reducedMotion;
    final floor = size.height - 14;
    // A soft glow behind the pair.
    final glow = Offset(size.width / 2, floor - 30);
    g.fillRadial(Shapes.ellipse(glow, size.width * 0.95, 150), [white.fade(0.85), white.fade(0)], glow, 10, size.width * 0.45);
    g.fill(Shapes.ellipse(Offset(size.width / 2, floor + 2), size.width * 0.62, 18), hex(0xE9D6F5).fade(0.7));

    if (quiet) {
      // Stars for a sleepy day.
      for (var index = 0; index < 9; index++) {
        final p = Offset(30 + Ease.hash(index, 4) * (size.width - 60), 14 + Ease.hash(index, 8) * 70);
        final twinkle = reduced ? 0.8 : 0.55 + 0.35 * math.sin(time * 1.4 + index);
        g.fill(Shapes.sparkle(p, 4.0 + index % 3), hex(0xB9A7FF).fade(twinkle));
      }
    } else {
      bunting(g, size.width, time, reduced);
      for (var index = 0; index < 16; index++) {
        final x = 16 + Ease.hash(index, 21) * (size.width - 32);
        final fall = reduced ? 0.0 : (time * 12 + index * 9) % 40;
        final y = 34 + Ease.hash(index, 33) * 90 + fall * 0.25;
        final piece = g.copy()
          ..translateBy(x, y)
          ..rotate(index + (reduced ? 0 : time * 0.8));
        piece.fill(
          Shapes.roundedRect(const Rect.fromLTWH(-3, -1.6, 6, 3.2), 0.8),
          ConfettiPalette.colors[index % ConfettiPalette.colors.length].fade(0.85),
        );
      }
    }

    final petContext = w.PoseContext(time: time, reducedMotion: reduced, seed: look.seed);
    final companionContext = w.PoseContext(time: time, reducedMotion: reduced, seed: look.seed + 0x5EED);
    final petX = look.showCompanion ? size.width * 0.33 : size.width * 0.5;
    PetRenderer.draw(petPose(quiet: quiet, time: time, context: petContext), g, Offset(petX, floor), 1.5, PetPalette(look.petColor),
        accessory: look.petAccessory);
    if (look.showCompanion) {
      FeatureArt.drawCompanion(companionPose(recap, companionContext), g, Offset(size.width * 0.69, floor + 4), 1.18,
          accessory: look.companionAccessory, time: time);
    }
  }

  /// Mochi raises a paw "ta-da" and does a little hop now and then; curled up asleep on a quiet day.
  static PetPose petPose({required bool quiet, required double time, required w.PoseContext context}) {
    if (quiet) return w.PetPoseEvaluator.pose(PetAnimation.curl, elapsed: 0, context: context);
    final cycle = time % 4.0;
    if (!context.reducedMotion && cycle < 1.0) {
      return w.PetPoseEvaluator.pose(PetAnimation.happyBounce, elapsed: cycle, duration: 1.0, context: context);
    }
    final pose = w.PetPoseEvaluator.pose(PetAnimation.idle, elapsed: 0, context: context);
    final raise = context.reducedMotion ? 1.0 : Ease.smooth(Ease.segment(cycle, 1.0, 1.35));
    return pose
      ..rightArm = 0.92 * raise
      ..eyes = PetEyes.happy
      ..mouth = PetMouth.grin
      ..blush = 0.8
      ..earPerk = 0.7
      ..lookX = 0.35;
  }

  /// Patch holds up a trophy for a day with finished turns, waves otherwise, and rests on a quiet day.
  static CompanionPose companionPose(w.DailyRecap recap, w.PoseContext context) {
    if (recap.isQuiet) return w.CompanionPoseEvaluator.pose(w.CompanionAnimation.rest, elapsed: 0, context: context);
    if (recap.turnsFinished > 0 || recap.buildsPassed + recap.testsPassed > 0) {
      return w.CompanionPoseEvaluator.pose(w.CompanionAnimation.trophy, elapsed: 1.0, context: context);
    }
    return w.CompanionPoseEvaluator.pose(w.CompanionAnimation.greet, elapsed: 0.8, context: context)..eyes = VisorEyes.happy;
  }

  static void bunting(GContext g, double width, double time, bool reduced) {
    final string = Path()
      ..moveTo(-10, 10)
      ..quadraticBezierTo(width / 2, 46, width + 10, 10);
    g.stroke(string, hex(0xC9B6DA), 1.2);
    const count = 11;
    for (var index = 0; index < count; index++) {
      final u = (index + 0.5) / count;
      final x = -10 + u * (width + 20);
      final y = 10 + (1 - (2 * u - 1) * (2 * u - 1)) * 18;
      final sway = reduced ? 0.0 : 0.08 * math.sin(time * 1.8 + index);
      final flag = g.copy()
        ..translateBy(x, y)
        ..rotate(sway);
      final path = Path()
        ..moveTo(-8, 0)
        ..lineTo(8, 0)
        ..lineTo(0, 15)
        ..close();
      flag.fill(path, ConfettiPalette.colors[index % ConfettiPalette.colors.length]);
    }
  }

  @override
  bool shouldRepaint(RecapStagePainter old) => old.recap != recap || old.look != look || old.clock != clock || old.time != time;
}

/// The card as a picture to save or copy: at twice its size, the characters at a settled moment.
abstract final class RecapImage {
  static Future<ExportedImage> render(w.DailyRecap recap, RecapLook look, DateTime now, {double scale = 2}) async {
    final width = (RecapCardPainter.size.width * scale).round();
    final height = (RecapCardPainter.size.height * scale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale, scale);
    RecapCardPainter.paintCard(canvas, recap, look, now);
    RecapStagePainter.draw(GContext(canvas)..clip(RecapCardPainter.stage()), recap, look, 2.2);
    final picture = recorder.endRecording();
    // On white too, for apps that don't keep transparency.
    final onWhiteRecorder = ui.PictureRecorder();
    Canvas(onWhiteRecorder)
      ..drawColor(const Color(0xFFFFFFFF), BlendMode.src)
      ..drawPicture(picture);
    final onWhitePicture = onWhiteRecorder.endRecording();
    final image = await picture.toImage(width, height);
    final onWhite = await onWhitePicture.toImage(width, height);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final rgba = await onWhite.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      return ExportedImage(png: png!.buffer.asUint8List(), rgbaOnWhite: rgba!.buffer.asUint8List(), width: width, height: height);
    } finally {
      image.dispose();
      onWhite.dispose();
      picture.dispose();
      onWhitePicture.dispose();
    }
  }
}
