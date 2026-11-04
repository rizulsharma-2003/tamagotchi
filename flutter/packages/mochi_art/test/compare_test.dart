// Builds side-by-side comparison images (Swift on the left or top, Flutter on the right or
// bottom) for every PNG name present in both folders. Skipped unless both are given:
//
//   MOCHI_ART_SWIFT=<dir of Swift renders> MOCHI_ART_OUT=<dir of Dart renders> \
//     flutter test test/compare_test.dart
//
// Writes <MOCHI_ART_OUT>/compare/<name>.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/render.dart';

Future<ui.Image> _decode(File file) async {
  final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
  final frame = await codec.getNextFrame();
  return frame.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final swiftPath = Platform.environment['MOCHI_ART_SWIFT'];
  final outPath = Platform.environment['MOCHI_ART_OUT'];

  test(
    'side by side',
    () async {
      await loadArtFonts();
      final swiftDirs = swiftPath!.split(':').map(Directory.new).toList();
      final out = Directory(outPath!);
      final compare = Directory('${out.path}/compare')..createSync(recursive: true);
      for (final entity in out.listSync().whereType<File>()) {
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.png')) continue;
        final swiftFile = swiftDirs.map((d) => File('${d.path}/$name')).where((f) => f.existsSync()).firstOrNull;
        if (swiftFile == null) continue;
        final a = await _decode(swiftFile);
        final b = await _decode(entity);
        // Side by side for tall images, stacked for wide ones.
        final sideBySide = a.width < a.height * 1.6;
        const gap = 24.0;
        const header = 28.0;
        final width = sideBySide ? a.width + b.width + gap : (a.width > b.width ? a.width : b.width).toDouble();
        final height = sideBySide ? header + (a.height > b.height ? a.height : b.height) : header * 2 + a.height + b.height + gap;
        final size = Size(width.toDouble(), height.toDouble());
        final image = await renderImage(size, 1, (canvas) {
          canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
          void caption(String text, Offset at) => drawLabel(canvas, text, at, size: 18, color: const Color(0xFF333333), left: true);
          if (sideBySide) {
            caption('Swift', const Offset(4, header / 2));
            caption('Flutter', Offset(a.width + gap + 4, header / 2));
            canvas.drawImage(a, const Offset(0, header), Paint());
            canvas.drawImage(b, Offset(a.width + gap, header), Paint());
          } else {
            caption('Swift', const Offset(4, header / 2));
            canvas.drawImage(a, const Offset(0, header), Paint());
            caption('Flutter', Offset(4, header + a.height + gap + header / 2));
            canvas.drawImage(b, Offset(0, header * 2 + a.height + gap), Paint());
          }
        });
        await writePng('compare/$name', image);
      }
      expect(compare.existsSync(), isTrue);
    },
    skip: swiftPath == null || outPath == null ? 'set MOCHI_ART_SWIFT and MOCHI_ART_OUT to build comparisons' : false,
    timeout: Timeout.none,
  );
}
