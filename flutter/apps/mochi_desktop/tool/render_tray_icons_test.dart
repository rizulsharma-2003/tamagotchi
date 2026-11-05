// Draws the tray icon (Mochi's face and ears, transparent around it) with mochi_art, at the sizes Windows asks for
// (16, 20, 24, 32, 40, 48 px for 100–300% scaling) and the macOS menu bar's 18 pt (36 px at 2x). Writes PNGs into
// build/tray_icons/; tool/make_icons.py packs them into assets/tray/tray_icon.ico and copies tray_icon.png.
//
//   flutter test tool/render_tray_icons_test.dart && python3 tool/make_icons.py

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';

void main() {
  testWidgets('render the tray icons', (tester) async {
    final out = Directory('build/tray_icons')..createSync(recursive: true);
    for (final size in [16, 20, 24, 32, 36, 40, 48, 64, 256]) {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final s = size.toDouble();
        // Mochi's head and ears fill the square; the body is cropped by the bottom edge.
        final pose = PetPose()..lookX = 0;
        PetRenderer.draw(
          pose,
          GContext(canvas),
          Offset(s / 2, s * 1.06),
          s / 64,
          PetPalette(PetColor.cream),
          detail: size <= 24 ? RenderDetail.tiny : RenderDetail.standard,
        );
        final image = await recorder.endRecording().toImage(size, size);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${out.path}/tray_$size.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });
}
