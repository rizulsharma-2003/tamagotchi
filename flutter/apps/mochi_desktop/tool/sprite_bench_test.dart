// How much a frame of the taskbar pet costs to draw, with the art drawn every frame and with pictures of poses
// (W30), on this machine's software rasterizer (the closest thing to the VM's WARP): the walk at 25 frames a second and
// the idle loop at 12, at 150%. Prints the median per frame.
//
//   flutter test tool/sprite_bench_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/ui/pet/pose_sprites.dart';

void main() {
  testWidgets('a frame: the art vs a picture', (tester) async {
    await tester.runAsync(() async {
      final library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync());
      const ratio = 1.5, box = Size(64, 40), scale = 40 * 0.92 / 66;
      const at = Offset(32, 38.8);
      final sprites = PoseSprites();
      for (final (name, animation, fps) in [('walk', PetAnimation.walk, 25), ('idle', PetAnimation.idle, 12)]) {
        final track = library.petTrack(animation)!;
        final q = fps > 15 ? 1 / 30 : 1 / 15;
        Future<int> frame(double t, {required bool pictures}) async {
          final watch = Stopwatch()..start();
          final time = pictures ? (t / q).round() * q : t;
          final pose = track.at(time);
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)..scale(ratio);
          void art(Canvas c, Offset o) =>
              PetRenderer.draw(pose, GContext(c), o, scale, PetPalette(PetColor.cream), detail: RenderDetail.tiny);
          if (pictures) {
            sprites.draw(canvas, '$name ${pose.toJson()}', at: at, bounds: (Offset.zero & box).shift(-at), ratio: ratio, paint: (c) => art(c, Offset.zero));
          } else {
            art(canvas, at);
          }
          final image = await recorder.endRecording().toImage((box.width * ratio).round(), (box.height * ratio).round());
          image.dispose();
          return watch.elapsedMicroseconds;
        }

        // Warm up (and fill the pictures: one loop).
        for (var i = 0; i < 4 * fps; i++) {
          await frame(i / fps, pictures: true);
          await frame(i / fps, pictures: false);
        }
        final direct = <int>[], copied = <int>[];
        for (var i = 0; i < 8 * fps; i++) {
          final t = 0.013 + i / fps;
          direct.add(await frame(t, pictures: false));
          copied.add(await frame(t, pictures: true));
        }
        int median(List<int> values) => (List.of(values)..sort())[values.length ~/ 2];
        // ignore: avoid_print
        print('$name at $fps fps: the art ${median(direct)} µs a frame, a picture ${median(copied)} µs '
            '(${(100 - 100 * median(copied) / median(direct)).round()}% less); pictures kept ${sprites.length}, '
            '${(sprites.bytes / 1024).round()} KB');
      }
    });
  });
}
