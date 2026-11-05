import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';

/// The camera, looking for the Mac's pairing QR code; closes with the first `mochi://pair` link it sees.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  static Future<String?> open(BuildContext context) =>
      Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const ScannerScreen()));

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue;
      if (text == null || !text.startsWith('mochi://pair')) continue;
      _done = true;
      Navigator.of(context).pop(text);
      return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: const Text('Scan the code on your Mac or PC'),
      foregroundColor: Colors.white,
      backgroundColor: Colors.black,
      titleTextStyle: context.type.headline.copyWith(color: Colors.white),
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _detected,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Text(
                error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Mochi needs the camera to scan the code. Allow it in Android Settings › Apps › Mochi › Permissions, '
                          'or go back and paste the pairing link instead.'
                    : "The camera didn't start. Go back and paste the pairing link instead.",
                textAlign: TextAlign.center,
                style: context.type.body.copyWith(color: Colors.white),
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.card),
                border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 3),
              ),
            ),
          ),
        ),
        Positioned(
          left: Space.xl,
          right: Space.xl,
          bottom: Space.xl * 2 + MediaQuery.paddingOf(context).bottom,
          child: Text(
            "Point the camera at the QR code in Mochi's Settings › Phones on your Mac or PC.",
            textAlign: TextAlign.center,
            style: context.type.subheadline.copyWith(color: Colors.white),
          ),
        ),
      ],
    ),
  );
}
