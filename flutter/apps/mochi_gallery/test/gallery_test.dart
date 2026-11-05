// Loads the recorded pose tracks and walks through every page of the gallery. With
// MOCHI_ART_OUT set, also saves a screenshot of each page there (labels use the test font).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_gallery/main.dart';
import 'package:mochi_gallery/tracks.dart';

void main() {
  testWidgets('the pose tracks cover every animation', (tester) async {
    final library = (await tester.runAsync(() => PoseLibrary.load(rootBundle)))!;
    expect(library.pet.map((t) => t.animation).toSet(), PetAnimation.values.where((a) => a != PetAnimation.scripted).toSet());
    expect(library.companion.length, CompanionAnimation.values.length - 2);
    expect(library.interactions.length, InteractionID.values.length);
    // Playback blends samples and wraps around.
    final idle = library.petTrack(PetAnimation.idle);
    expect(idle.at(0.5).breath, isNot(idle.at(1.5).breath));
    expect(idle.at(idle.length + 0.5).breath, closeTo(idle.at(0.5).breath, 1e-9));
  });

  testWidgets('every page renders', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final library = (await tester.runAsync(() => PoseLibrary.load(rootBundle)))!;
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GalleryApp(library: Future.value(library)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 1300));

    final out = Platform.environment['MOCHI_ART_OUT'];
    for (final (index, name) in const [(0, 'mochi'), (1, 'patch'), (2, 'room'), (3, 'props')]) {
      if (index > 0) {
        await tester.tap(
          find.byType(NavigationDestination).evaluate().isEmpty
              ? find.text(['Mochi', 'Patch', 'Room', 'Props'][index])
              : find.byType(NavigationDestination).at(index),
        );
        await tester.pump(const Duration(milliseconds: 700));
      }
      expect(tester.takeException(), isNull);
      if (out != null) {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(() => boundary.toImage()))!;
        final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
        Directory(out).createSync(recursive: true);
        File('$out/gallery-$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
      }
    }
  });
}
