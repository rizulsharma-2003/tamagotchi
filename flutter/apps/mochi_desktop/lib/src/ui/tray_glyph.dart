// The classic tray icon (Settings › Desktop Pet › "Classic tray icon"; the Mac's "Classic icon", MenuBarGlyph.swift and
// StatusItemController's classic animation): Mochi's silhouette with its expression cut out, in one colour (white on a
// dark taskbar, near-black on a light one), in the notification area. It blinks now and then, a little light pulses
// while Claude works (Patch's antenna bulb, on and off every 0.8 s: never flashing), it hops with sparkles when a turn
// completes, and a dot shows what's waiting for you (the Mac's badge). It's drawn only when something visible changes
// (one timer for the next blink, pulse or hop), never while nobody can see the screen, and stays still with "Static",
// or with Windows' animation effects off.
//
// Windows takes tray icons as .ico files: each frame is drawn at 16 to 48 pixels (for 100% to 300%), packed as PNGs in
// one .ico in Mochi's folder (`tray/`), and handed to the tray once; a frame already drawn is reused.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../core/desktop_settings.dart';
import '../core/notifications.dart' show AttentionLevel;
import '../core/pc_rhythm.dart';
import '../core/pet_cues.dart';
import '../platform/system.dart';
import 'pet/pet_director.dart' show PetMood;
import 'shell.dart';

/// What the icon shows (the Mac's `MenuBarStatus.mood`).
enum GlyphMood { content, sleeping, watching, waiting, concerned, celebrating, offline, paused }

/// One picture of the icon.
@immutable
class GlyphFrame {
  const GlyphFrame({
    required this.mood,
    this.blink = false,
    this.bulb,
    this.bounce = 0,
    this.sparkle = 0.25,
    this.badge,
    this.light = false,
  });

  final GlyphMood mood;
  final bool blink;

  /// Patch's antenna bulb while Claude works: lit or not (null: Claude isn't working).
  final bool? bulb;

  /// A celebration hop (art units, 0–2.4) and the sparkles' size (0–1).
  final double bounce;
  final double sparkle;
  final AttentionLevel? badge;

  /// For a light taskbar (drawn near-black), or a dark one (white).
  final bool light;

  /// A name for the frame's file.
  String get key =>
      '${mood.name}-${blink ? 'b' : 'o'}-${bulb == null ? 'n' : (bulb! ? 'l' : 'd')}-${(bounce * 10).round()}-'
      '${(sparkle * 100).round()}-${badge?.name ?? 'none'}-${light ? 'light' : 'dark'}';

  @override
  bool operator ==(Object other) => other is GlyphFrame && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

abstract final class TrayGlyph {
  /// The sizes in each .ico: 100% to 300% (Windows picks the one for the display).
  static const List<int> sizes = [16, 20, 24, 32, 40, 48];

  /// What a screen reader (and the tooltip) says for [mood] (the Mac's `MenuBarGlyph.description`).
  static String describe(GlyphMood mood, String name, {bool session = false}) => switch (mood) {
    GlyphMood.content => session ? '$name: a Claude Code session is open' : name,
    GlyphMood.sleeping => '$name is napping',
    GlyphMood.watching => '$name: Claude is working',
    GlyphMood.waiting => '$name: Claude is waiting for you',
    GlyphMood.concerned => '$name: Claude hit a snag',
    GlyphMood.celebrating => '$name: Claude finished',
    GlyphMood.offline => '$name can’t hear Claude Code',
    GlyphMood.paused => '$name: reactions paused',
  };

  /// [frame] in a square [size] pixels big: the Mac's 19 × 18-point glyph, scaled to fit.
  static void draw(Canvas canvas, double size, GlyphFrame frame) {
    final ink = frame.light ? const Color(0xFF1C1B1F) : const Color(0xFFFFFFFF);
    final k = size / 19;
    canvas.save();
    // The Mac draws upwards from the bottom: flip, and centre the 18-point height.
    canvas.translate(0, size - 0.5 * k);
    canvas.scale(k, -k);
    canvas.saveLayer(const Rect.fromLTWH(-2, -2, 23, 23), Paint());
    final fill = Paint()
      ..color = ink
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.save();
    canvas.translate(0, frame.bounce);
    _pet(canvas, frame, fill, stroke);
    canvas.restore();
    if (frame.mood == GlyphMood.celebrating) {
      for (final (x, y, r) in [(1.6, 14.5 - frame.bounce * 0.3, 1.8), (17.2, 15.2, 1.5)]) {
        _sparkle(canvas, Offset(x, y), r * (0.7 + 0.3 * frame.sparkle), fill);
      }
    }
    final bulb = frame.bulb;
    if (bulb != null) {
      // Patch's antenna bulb (the Mac draws his head beside Mochi; a square icon has room for the light).
      const centre = Offset(16.6, 16.4);
      if (bulb) {
        canvas.drawCircle(centre, 1.55, fill);
      } else {
        canvas.drawCircle(centre, 1.15, stroke..strokeWidth = 0.8);
      }
    }
    canvas.restore();
    final badge = frame.badge;
    if (badge != null) {
      // The Mac's badge colours, on a rim of the taskbar's colour.
      final colour = switch (badge) {
        AttentionLevel.info => const Color(0xFF9A93A6),
        AttentionLevel.attention => const Color(0xFFFF9F0A),
        AttentionLevel.alert => const Color(0xFFFF453A),
      };
      canvas.drawCircle(const Offset(16, 3.6), 3.4, Paint()..color = frame.light ? const Color(0xFFF3F3F3) : const Color(0xFF202020));
      canvas.drawCircle(const Offset(16, 3.6), 2.5, Paint()..color = colour);
    }
    canvas.restore();
  }

  static void _pet(Canvas canvas, GlyphFrame frame, Paint fill, Paint stroke) {
    // Body: a soft dome.
    final body = Path()
      ..moveTo(1.6, 3)
      ..cubicTo(1.2, 10.2, 4.6, 13.6, 9, 13.6)
      ..cubicTo(13.4, 13.6, 16.8, 10.2, 16.4, 3)
      ..cubicTo(16.3, 1.4, 12.6, 1, 9, 1)
      ..cubicTo(5.4, 1, 1.7, 1.4, 1.6, 3)
      ..close();
    canvas.drawPath(body, fill);
    // Ears.
    final droop = frame.mood == GlyphMood.concerned || frame.mood == GlyphMood.sleeping ? 1.2 : 0.0;
    for (final side in [-1.0, 1.0]) {
      final baseX = 9 + side * 3.6;
      canvas.drawPath(
        Path()
          ..moveTo(baseX - 2.3, 11.6)
          ..lineTo(baseX + side * (0.9 + droop), 16.6 - droop)
          ..lineTo(baseX + 2.3, 11.6)
          ..close(),
        fill,
      );
    }
    // The face is cut out.
    final cut = Paint()..blendMode = BlendMode.clear;
    final cutStroke = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const left = Offset(6.3, 7), right = Offset(11.7, 7);
    final closed = frame.blink || frame.mood == GlyphMood.sleeping || frame.mood == GlyphMood.paused;
    switch (frame.mood) {
      case GlyphMood.celebrating:
        for (final eye in [left, right]) {
          _arc(canvas, eye, up: true, paint: cutStroke);
        }
        canvas.drawOval(const Rect.fromLTWH(7.9, 3.2, 2.2, 1.7), cut);
      case GlyphMood.offline:
        for (final eye in [left, right]) {
          canvas.drawRect(Rect.fromLTWH(eye.dx - 1.3, eye.dy - 0.4, 2.6, 0.9), cut);
        }
      case GlyphMood.concerned:
        for (final eye in [left, right]) {
          canvas.drawOval(Rect.fromLTWH(eye.dx - 0.95, eye.dy - 1.4, 1.9, 2.5), cut);
        }
        for (final (eye, side) in [(left, -1.0), (right, 1.0)]) {
          canvas.drawLine(Offset(eye.dx + side * 1.5, eye.dy + 2.1), Offset(eye.dx - side * 1.0, eye.dy + 2.9), cutStroke..strokeWidth = 0.9);
        }
      case GlyphMood.waiting:
        for (final eye in [left, right]) {
          canvas.drawOval(Rect.fromLTWH(eye.dx - 1.3, eye.dy - 1.7, 2.6, 3.5), cut);
        }
      default:
        if (closed) {
          for (final eye in [left, right]) {
            _arc(canvas, eye, up: false, paint: cutStroke);
          }
        } else {
          final look = frame.mood == GlyphMood.watching ? 0.7 : 0.0;
          for (final eye in [left, right]) {
            canvas.drawOval(Rect.fromLTWH(eye.dx - 1.1 + look, eye.dy - 1.5, 2.2, 3.1), cut);
          }
        }
    }
    if (frame.mood == GlyphMood.sleeping) {
      canvas.drawPath(
        Path()
          ..moveTo(14.6, 17)
          ..lineTo(17.6, 17)
          ..lineTo(14.6, 14.2)
          ..lineTo(17.6, 14.2),
        stroke..strokeWidth = 1,
      );
    }
    if (frame.mood == GlyphMood.paused) {
      canvas.drawRect(const Rect.fromLTWH(14.8, 13.6, 1.1, 3.6), fill);
      canvas.drawRect(const Rect.fromLTWH(16.8, 13.6, 1.1, 3.6), fill);
    }
  }

  static void _arc(Canvas canvas, Offset centre, {required bool up, required Paint paint}) {
    final y = centre.dy + (up ? -0.5 : 0.6);
    canvas.drawPath(
      Path()
        ..moveTo(centre.dx - 1.4, y)
        ..quadraticBezierTo(centre.dx, centre.dy + (up ? 2.0 : -1.6), centre.dx + 1.4, y),
      paint..strokeWidth = 1.15,
    );
  }

  static void _sparkle(Canvas canvas, Offset centre, double radius, Paint paint) {
    final path = Path();
    for (var index = 0; index < 8; index++) {
      final angle = index * math.pi / 4;
      final r = index.isEven ? radius : radius * 0.3;
      final point = Offset(centre.dx + math.cos(angle) * r, centre.dy + math.sin(angle) * r);
      index == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path..close(), paint);
  }

  /// [frame] as an .ico with a PNG for each of [sizes].
  static Future<Uint8List> ico(GlyphFrame frame) async {
    final pngs = <Uint8List>[];
    for (final size in sizes) {
      final recorder = ui.PictureRecorder();
      draw(Canvas(recorder), size.toDouble(), frame);
      final picture = recorder.endRecording();
      final image = await picture.toImage(size, size);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      pngs.add(data!.buffer.asUint8List());
    }
    return pack(sizes, pngs);
  }

  /// An .ico holding [pngs] (PNG-compressed entries, as Windows has read since Vista), [sizes] square.
  static Uint8List pack(List<int> sizes, List<Uint8List> pngs) {
    final header = 6 + 16 * pngs.length;
    final total = header + pngs.fold<int>(0, (sum, png) => sum + png.length);
    final bytes = ByteData(total);
    bytes
      ..setUint16(0, 0, Endian.little)
      ..setUint16(2, 1, Endian.little)
      ..setUint16(4, pngs.length, Endian.little);
    var offset = header;
    for (var i = 0; i < pngs.length; i++) {
      final entry = 6 + 16 * i;
      final size = sizes[i] >= 256 ? 0 : sizes[i];
      bytes
        ..setUint8(entry, size)
        ..setUint8(entry + 1, size)
        ..setUint8(entry + 2, 0)
        ..setUint8(entry + 3, 0)
        ..setUint16(entry + 4, 1, Endian.little)
        ..setUint16(entry + 6, 32, Endian.little)
        ..setUint32(entry + 8, pngs[i].length, Endian.little)
        ..setUint32(entry + 12, offset, Endian.little);
      offset += pngs[i].length;
    }
    final out = bytes.buffer.asUint8List();
    offset = header;
    for (final png in pngs) {
      out.setRange(offset, offset + png.length, png);
      offset += png.length;
    }
    return out;
  }
}

/// Runs the classic tray icon while Mochi lives there ([DesktopStyle.icon]); the app's own icon otherwise.
class TrayGlyphController {
  TrayGlyphController({
    required this.shell,
    required this.settings,
    required this.folder,
    required this.mood,
    required Stream<PetCue> cues,
    required this.motion,
    this.rhythm,
    this.badge,
    this.offline,
    this.sessionOpen,
    this.lightTaskbar,
    DateTime Function()? clock,
    math.Random? random,
    Future<String> Function(GlyphFrame frame)? write,
  }) : _write = write,
       _clock = clock ?? DateTime.now,
       _random = random ?? math.Random() {
    settings.addListener(_changed);
    motion.addListener(_changed);
    rhythm?.addListener(_changed);
    _cues = cues.listen(_cue);
    _nextBlink = _clock().add(_blinkGap());
    _changed();
  }

  final DesktopShell shell;
  final DesktopSettings settings;

  /// Where the frames' .ico files go (`<Mochi's folder>/tray`).
  final String folder;
  final PetMood Function() mood;
  final SystemMotion motion;
  final PcRhythm? rhythm;
  final AttentionLevel? Function()? badge;
  final bool Function()? offline;
  final bool Function()? sessionOpen;

  /// Whether the taskbar is light (Windows' "SystemUsesLightTheme"); null: dark.
  final bool Function()? lightTaskbar;
  final DateTime Function() _clock;
  final math.Random _random;
  late final StreamSubscription<PetCue> _cues;

  /// Writes a frame's .ico and says where (tests write nothing).
  final Future<String> Function(GlyphFrame frame)? _write;

  Timer? _timer;
  GlyphFrame? _shown;
  bool _active = false;
  bool _disposed = false;
  late DateTime _nextBlink;
  DateTime? _celebrationStart;
  final Set<String> _written = {};

  /// The frame showing now (null: the app's own icon), and the timer for the next change (tests).
  GlyphFrame? get shown => _shown;
  bool get ticking => _timer != null;

  Duration _blinkGap() => Duration(milliseconds: 3500 + _random.nextInt(4000));

  GlyphMood get glyphMood {
    if (settings.pauseReactions) return GlyphMood.paused;
    if (offline?.call() ?? false) return GlyphMood.offline;
    return switch (mood()) {
      PetMood.napping => GlyphMood.sleeping,
      PetMood.watching => GlyphMood.watching,
      PetMood.needsYou => GlyphMood.waiting,
      PetMood.happy => GlyphMood.celebrating,
      PetMood.concerned => GlyphMood.concerned,
      PetMood.relaxed => GlyphMood.content,
    };
  }

  void _cue(PetCue cue) {
    if (cue == PetCue.finished || cue == PetCue.celebrate) _celebrationStart = _clock();
    _changed();
  }

  /// Something that may change the icon happened (a setting, a session, the PC's rhythm): look again now.
  void refresh() => _changed();

  void _changed() {
    if (_disposed) return;
    final active = settings.petStyle == DesktopStyle.icon;
    if (!active) {
      _timer?.cancel();
      _timer = null;
      if (_active || _shown != null) {
        _active = false;
        _shown = null;
        unawaited(shell.setTrayIcon(tooltip: 'Mochi'));
      }
      return;
    }
    _active = true;
    _step();
  }

  /// The frame for now, and when the next visible change comes (the Mac's `animationStep`).
  void _step() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || !_active) return;
    final now = _clock();
    final glyph = glyphMood;
    final working = glyph == GlyphMood.watching;
    final still = settings.trayAnimation == TrayAnimation.off || motion.reduced;
    var next = GlyphFrame(mood: glyph, bulb: working ? true : null, badge: badge?.call(), light: lightTaskbar?.call() ?? false);
    var wake = const Duration(days: 1);
    if (glyph == GlyphMood.celebrating && _celebrationStart == null) _celebrationStart = now;
    if (glyph != GlyphMood.celebrating) _celebrationStart = null;
    if (!still) {
      // Natural, occasional blinks.
      if (now.isAfter(_nextBlink.add(const Duration(milliseconds: 140)))) _nextBlink = now.add(_blinkGap());
      Duration until(DateTime at) => at.difference(now);
      if (!now.isBefore(_nextBlink)) {
        next = _with(next, blink: true);
        wake = _min(wake, until(_nextBlink.add(const Duration(milliseconds: 140))));
      } else {
        wake = _min(wake, until(_nextBlink));
      }
      // A gentle pulse while Claude works: on and off every 0.8 s.
      if (working) {
        final cycle = now.microsecondsSinceEpoch / 1e6 / 1.6;
        final fraction = cycle - cycle.floorToDouble();
        next = _with(next, bulb: fraction < 0.5);
        wake = _min(wake, Duration(microseconds: (((fraction < 0.5 ? 0.5 : 1.0) - fraction) * 1.6e6).ceil() + 10000));
      }
      final start = _celebrationStart;
      if (glyph == GlyphMood.celebrating && start != null) {
        final t = now.difference(start).inMicroseconds / 1e6;
        final hops = settings.trayAnimation == TrayAnimation.full ? 3.0 : 2.0;
        double phase(double t) => ((t * 1.5) % 1 * 4).round() / 4 % 1;
        if (t < hops * 0.42) {
          next = _with(next, bounce: (2.4 * math.sin(math.pi * t / 0.42).abs() / 0.6).round() * 0.6, sparkle: phase(t));
          wake = _min(wake, const Duration(milliseconds: 83));
        } else if (t < 2.6) {
          next = _with(next, sparkle: phase(t));
          wake = _min(wake, const Duration(milliseconds: 125));
        }
      }
    }
    if (next != _shown) {
      _shown = next;
      unawaited(_show(next, glyph));
    }
    // Nothing moves while nobody can see the screen; it carries on when it's back.
    // Still, it looks again every few seconds (a nap begins, a finish fades).
    if (rhythm?.unseen ?? false) return;
    if (still) wake = const Duration(seconds: 5);
    _timer = Timer(wake < const Duration(milliseconds: 50) ? const Duration(milliseconds: 50) : _min(wake, const Duration(seconds: 5)), _step);
  }

  static Duration _min(Duration a, Duration b) => a < b ? a : b;

  static GlyphFrame _with(GlyphFrame f, {bool? blink, bool? bulb, double? bounce, double? sparkle}) => GlyphFrame(
    mood: f.mood,
    blink: blink ?? f.blink,
    bulb: bulb ?? f.bulb,
    bounce: bounce ?? f.bounce,
    sparkle: sparkle ?? f.sparkle,
    badge: f.badge,
    light: f.light,
  );

  /// Writes the frame's .ico in [folder] (once) and says where.
  Future<String> _writeFrame(GlyphFrame frame) async {
    final path = '$folder${Platform.pathSeparator}glyph1-${frame.key}.ico';
    if (!_written.contains(path) && !File(path).existsSync()) {
      final bytes = await TrayGlyph.ico(frame);
      Directory(folder).createSync(recursive: true);
      await File('$path.tmp').writeAsBytes(bytes, flush: true);
      File('$path.tmp').renameSync(path);
    }
    _written.add(path);
    return path;
  }

  /// Writes the frame's .ico (once) and hands it to the tray.
  Future<void> _show(GlyphFrame frame, GlyphMood glyph) async {
    try {
      final path = await (_write ?? _writeFrame)(frame);
      if (_disposed || _shown != frame || !_active) return;
      await shell.setTrayIcon(
        path: path,
        tooltip: TrayGlyph.describe(glyph, settings.petName, session: sessionOpen?.call() ?? false),
      );
    } on Object catch (error) {
      debugPrint('Mochi: the tray icon could not be drawn (${error.runtimeType})');
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    settings.removeListener(_changed);
    motion.removeListener(_changed);
    rhythm?.removeListener(_changed);
    unawaited(_cues.cancel());
  }
}
