import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// A QR code for [data], dark modules on white with the standard 4-module quiet zone (white in both themes, so
/// phone cameras read it).
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, this.size = 220, this.semanticLabel = 'Pairing QR code'});

  final String data;
  final double size;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M));
    return Semantics(
      container: true,
      image: true,
      label: semanticLabel,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: CustomPaint(painter: _QrPainter(image)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  static const int quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final count = image.moduleCount + quietZone * 2;
    final module = size.shortestSide / count;
    final paint = Paint()
      ..color = const Color(0xFF1B1410)
      ..isAntiAlias = false;
    final path = Path();
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (!image.isDark(row, col)) continue;
        // A hair of overlap so neighbouring modules don't show seams.
        path.addRect(Rect.fromLTWH((col + quietZone) * module, (row + quietZone) * module, module + 0.5, module + 0.5));
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
