import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/mochi_art.dart';

import '../model/pocket_model.dart';
import '../scene/pose_library.dart';
import '../scene/scene_director.dart';
import '../theme.dart';
import '../widgets/clay.dart';
import 'scanner_screen.dart';

/// Before pairing: join your Mac's Mochi Link room by scanning its QR code, pasting its link, or opening the link
/// (iOS/MochiPocket/PocketLink.swift `LinkCard`).
class PairingScreen extends StatelessWidget {
  const PairingScreen({super.key, required this.model, required this.library, this.scan});

  final PocketModel model;
  final PoseLibrary? library;

  /// Opens the camera and returns the scanned link (replaced in tests).
  final Future<String?> Function(BuildContext context)? scan;

  Future<void> _scan(BuildContext context) async {
    model.clearProblem();
    final text = await (scan ?? ScannerScreen.open)(context);
    if (text != null) await model.pair(text);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    await model.pair(data?.text ?? '');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PocketBackground(
      child: SafeArea(
        child: ListenableBuilder(
          listenable: model,
          builder: (context, _) {
            final p = context.palette;
            final problem = model.problem;
            return ListView(
              padding: const EdgeInsets.fromLTRB(Space.l, Space.xl, Space.l, Space.xl),
              children: [
                SizedBox(height: 150, child: _WavingMochi(library: library)),
                const SizedBox(height: Space.l),
                Semantics(
                  header: true,
                  child: Text('Pair with your Mac or PC', textAlign: TextAlign.center, style: context.type.largeTitle),
                ),
                const SizedBox(height: Space.s),
                Text(
                  'Mochi on this phone talks to Mochi on your Mac or PC through Mochi Link, end-to-end encrypted. '
                  'What you send reaches it in under a second.',
                  textAlign: TextAlign.center,
                  style: context.type.subheadline.copyWith(color: p.inkSecondary),
                ),
                const SizedBox(height: Space.xl),
                ClayCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(header: true, child: Text('On your Mac or PC', style: context.type.headline)),
                      const SizedBox(height: Space.m),
                      _step(context, 1, "Open Mochi's Settings › Phones."),
                      _step(context, 2, 'Click “Pair a Phone…”.'),
                      _step(context, 3, 'Scan the code it shows, or copy its pairing link and paste it here.'),
                      const SizedBox(height: Space.l),
                      if (model.pairing)
                        Semantics(
                          liveRegion: true,
                          child: Row(
                            children: [
                              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
                              const SizedBox(width: Space.m),
                              Expanded(
                                child: Text('Pairing with ${model.pairingWith ?? 'your computer'}…', style: context.type.subheadline),
                              ),
                            ],
                          ),
                        )
                      else ...[
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => _scan(context),
                            icon: const Icon(Icons.qr_code_scanner_rounded),
                            label: const Text('Scan the Code'),
                          ),
                        ),
                        const SizedBox(height: Space.s),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _paste,
                            icon: const Icon(Icons.content_paste_rounded),
                            label: const Text('Paste Link'),
                          ),
                        ),
                      ],
                      if (problem != null) ...[
                        const SizedBox(height: Space.m),
                        Semantics(
                          liveRegion: true,
                          child: NoteLabel(text: problem, icon: Icons.warning_rounded, tint: p.warning, textColor: p.warning),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Space.l),
                Text(
                  'The code works once and lasts 10 minutes. Only your devices hold the key; the relay just passes sealed messages along.',
                  textAlign: TextAlign.center,
                  style: context.type.footnote,
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _step(BuildContext context, int number, String text) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: p.tint.withValues(alpha: p.isDark ? 0.2 : 0.12),
              ),
              child: Text(
                '$number',
                style: context.type.caption.copyWith(color: p.tint, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: Space.m),
          Expanded(
            child: Text(text, semanticsLabel: 'Step $number: $text', style: context.type.subheadline),
          ),
        ],
      ),
    );
  }
}

/// Mochi waving hello while you pair (calmer when animations are off).
class _WavingMochi extends StatefulWidget {
  const _WavingMochi({required this.library});

  final PoseLibrary? library;

  @override
  State<_WavingMochi> createState() => _WavingMochiState();
}

class _WavingMochiState extends State<_WavingMochi> with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _clock = ValueNotifier(0);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) => _clock.value = elapsed.inMicroseconds / 1e6)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calm = MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: ValueListenableBuilder<double>(
        valueListenable: _clock,
        builder: (context, time, _) {
          final track = widget.library?.petTrack(PetAnimation.waveGently);
          final pose = track == null ? PetPose() : SceneDirector.calmed<PetPose>(track, time, calm: calm);
          return CustomPaint(
            painter: PetPainter(pose: pose, fill: 0.85, dark: context.palette.isDark),
          );
        },
      ),
    );
  }
}
