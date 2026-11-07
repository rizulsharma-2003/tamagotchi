// Mochi's and Patch's poses as pictures (docs/SPRINT_2.md W30): each pose the taskbar pet shows is drawn once from the
// vector art into an image at the screen's resolution, and every later frame with the same pose copies that image
// instead of drawing the art again. Copying one image is a small part of drawing the art (dozens of anti-aliased paths),
// on the processor and on the graphics card, and Mochi's loops come round every few seconds.
//
// - A picture is drawn exactly where the art would be: at the same scale, and at the same fraction of a pixel (the
//   picture's origin keeps the fractional part of where it's drawn), so a copy lands on the same pixels the art would
//   have, to within what the art itself varies by when it's drawn a few pixels along (test/performance_test.dart).
//   Where the origin moves continuously (Mochi pottering beside Patch), the fraction is kept to a quarter of a pixel, so
//   the pictures can be reused.
// - Each picture's key is everything its drawing depends on: the pose itself (every field), the time-dependent bits
//   of Patch's drawing (CompanionRenderer.timeKey), the coat, what they wear, light or dark, the detail level, the size
//   and the display's scale. The last ones are the cache's context: when it changes (another display scale, another
//   coat, a costume, the theme), every picture is thrown away at once.
// - At most [PoseSprites.budget] bytes of pictures are kept; the least recently used go first.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

class PoseSprites {
  PoseSprites({this.budget = 16 << 20});

  /// Bytes of pictures kept at most.
  final int budget;

  final LinkedHashMap<String, ui.Image> _images = LinkedHashMap();
  int _bytes = 0;
  String? _context;

  /// Pictures copied, and pictures drawn (for the perf meter and tests).
  int hits = 0;
  int misses = 0;

  int get bytes => _bytes;
  int get length => _images.length;
  String? get context => _context;

  /// The pictures are for [context] (the display's scale, the coat, what's worn, light or dark, the size): when it
  /// changes, the old ones go.
  void use(String context) {
    if (context == _context) return;
    clear();
    _context = context;
  }

  /// Draws the picture for [key] on [canvas] with its origin at [at] (logical pixels), drawing it first with [paint]
  /// (which draws around the origin, in logical pixels) if it isn't kept yet. The picture holds what [paint] draws
  /// within [bounds] (relative to the origin): everything the art can reach that can be seen. [ratio] is the display's
  /// scale. [moving]: the origin moves across from frame to frame (its fraction of a pixel is kept to a quarter).
  void draw(
    Canvas canvas,
    String key, {
    required Offset at,
    required Rect bounds,
    required double ratio,
    required void Function(Canvas canvas) paint,
    bool moving = false,
  }) {
    // Where the origin lands, in physical pixels, and its fraction of a pixel (to a quarter across, if it moves).
    final px = at.dx * ratio, py = at.dy * ratio;
    final fx = moving ? _quarter(px - px.floorToDouble()) : px - px.floorToDouble(), fy = py - py.floorToDouble();
    if (bounds.isEmpty) return;
    // A picture is for one size and placement of its frame too (the visible part of the window can change).
    final fullKey =
        '$key@$fx,$fy#${(bounds.left * ratio).round()},${(bounds.top * ratio).round()},'
        '${(bounds.right * ratio).round()},${(bounds.bottom * ratio).round()}';
    // The picture's origin pixel: far enough in for everything inside [bounds].
    final ox = (-bounds.left * ratio).ceilToDouble() + 1, oy = (-bounds.top * ratio).ceilToDouble() + 1;
    var image = _images.remove(fullKey);
    if (image != null) {
      hits++;
    } else {
      misses++;
      final width = math.max(1, (ox + bounds.right * ratio).ceil() + 1);
      final height = math.max(1, (oy + bounds.bottom * ratio).ceil() + 1);
      final recorder = ui.PictureRecorder();
      final offscreen = Canvas(recorder)
        ..translate(ox + fx, oy + fy)
        ..scale(ratio)
        ..clipRect(bounds);
      paint(offscreen);
      final picture = recorder.endRecording();
      image = picture.toImageSync(width, height);
      picture.dispose();
      _bytes += _size(image);
    }
    _images[fullKey] = image;
    _evict();
    // The picture's top-left pixel, on the pixel grid where the origin's fraction matches.
    final left = (px - fx).roundToDouble() - ox, top = (py - fy).roundToDouble() - oy;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(left / ratio, top / ratio, image.width / ratio, image.height / ratio),
      _paint,
    );
  }

  static final Paint _paint = Paint()..filterQuality = FilterQuality.low;

  static double _quarter(double fraction) => (fraction * 4).round() / 4 % 1;

  static int _size(ui.Image image) => image.width * image.height * 4;

  void _evict() {
    while (_bytes > budget && _images.length > 1) {
      final oldest = _images.keys.first;
      final image = _images.remove(oldest)!;
      _bytes -= _size(image);
      image.dispose();
    }
  }

  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _bytes = 0;
  }

  void dispose() => clear();
}
