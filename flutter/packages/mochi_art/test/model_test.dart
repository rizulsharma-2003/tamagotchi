// The Dart model behaves like the Swift one: same defaults, JSON keys and helper semantics.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';

import 'support/render.dart';

void main() {
  test('poses read the Swift JSON, with Swift defaults for missing keys', () {
    final pose = PetPose.fromJson({
      'eyes': 'happy',
      'mouth': 'grin',
      'held': 'coffee',
      'effects': [
        {'kind': 'heart', 'x': 0.4, 'y': 1.1, 'variant': 2},
      ],
    });
    expect(pose.eyes, PetEyes.happy);
    expect(pose.mouth, PetMouth.grin);
    expect(pose.held, HeldItem.coffee);
    expect(pose.lookX, 0.15);
    expect(pose.blush, 0.35);
    expect(pose.facing, 1);
    expect(pose.effects.single.kind, EffectKind.heart);
    expect(pose.effects.single.scale, 1);
    expect(pose.effects.single.variant, 2);
    final round = PetPose.fromJson(pose.toJson());
    expect(round.toJson(), pose.toJson());

    final companion = CompanionPose.fromJson({
      'antennaTint': 'working',
      'laptop': {'screen': 'code'},
    });
    expect(companion.facing, -1);
    expect(companion.antennaGlow, 0.35);
    expect(companion.antennaTint, AntennaTint.working);
    expect(companion.laptop.screen, LaptopScreen.code);
    expect(companion.laptop.openness, 1);
  });

  test('every exported reference pose parses', () {
    final gallery = referenceList('petGallery');
    expect(gallery.length, PetAnimation.values.length - 1);
    for (final entry in gallery) {
      expect(PetAnimation.values.map((a) => a.name), contains(entry['animation']));
    }
    for (final scene in referenceList('scenes')) {
      final frame = SceneFrame.fromJson(scene);
      expect(frame.companionVisible, isTrue);
      expect(SceneConfig.fromJson(scene).deskAccessory, Accessory.plant);
    }
  });

  test('mirroring turns the pose around', () {
    final pose = PetPose()
      ..leftArm = 1
      ..lookX = 0.5
      ..effects = [Effect(EffectKind.dust, x: 0.3, x2: 0.1, rotation: 0.2)];
    final mirrored = pose.mirrored();
    expect(mirrored.facing, -1);
    expect(mirrored.rightArm, 1);
    expect(mirrored.leftArm, 0);
    expect(mirrored.lookX, -0.5);
    expect(mirrored.effects.single.x, -0.3);
    expect(mirrored.effects.single.rotation, -0.2);
    expect(pose.effects.single.x, 0.3, reason: 'the original is untouched');
  });

  test('Ease matches TamagotchiCore', () {
    expect(Ease.smooth(0.5), 0.5);
    expect(Ease.hop(0.5), 1);
    expect(Ease.segment(5, 0, 10), 0.5);
    expect(Ease.fract(-0.25), 0.75);
    // SplitMix64 is deterministic and spread over 0…1.
    final values = [for (var i = 0; i < 200; i++) Ease.hash(i, 7)];
    expect(values.every((v) => v >= 0 && v < 1), isTrue);
    expect(values.toSet().length, 200);
    expect(Ease.hash(3, 9), Ease.hash(3, 9));
  });

  test('the room snaps furniture into its band and draws back to front', () {
    final room = RoomLayout();
    final rug = room.add(FurnitureCatalog.kind('rug')!, 0.5, 0.5)!;
    final shelf = room.add(FurnitureCatalog.kind('bookshelf')!, -1, 2)!;
    final clock = room.add(FurnitureCatalog.kind('clock')!, 0.5, 0.9)!;
    expect(rug.y, RoomLayout.rugBand.$1);
    expect(shelf.y, RoomLayout.floorBand.$2);
    expect(shelf.x, closeTo(20 / 360, 1e-9));
    expect(clock.y, RoomLayout.wallBand.$2);
    room.items.insert(0, room.items.removeAt(1));
    expect(room.drawingOrder.map((i) => i.kind), ['rug', 'clock', 'bookshelf']);
  });

  test('menu-bar fitting keeps a few bold effects and compresses leaps', () {
    final pose = PetPose()
      ..y = 0.5
      ..effects = [for (var i = 0; i < 6; i++) Effect(EffectKind.heart, y: 1.2), Effect(EffectKind.purr), Effect(EffectKind.ball, y: 0.2)];
    final fit = PetTinyFit.fit(pose);
    expect(fit.y, lessThan(0.3));
    expect(fit.effects.length, 4);
    expect(fit.effects.where((e) => e.kind == EffectKind.purr), isEmpty);
    expect(fit.effects.last.kind, EffectKind.ball);
  });

  test('listening turns the right ear towards you', () {
    final idle = PetPose()..facing = -1;
    final halfway = ListeningPose.pose(idle, elapsed: ListeningPose.turnDuration / 2, listening: false, time: 3);
    expect(halfway.headTurn, closeTo(0.5, 1e-9));
    expect(halfway.brows, Brows.none);
    final listening = ListeningPose.pose(idle, elapsed: 0, listening: true, time: 3);
    expect(listening.facing, 1);
    expect(listening.earListen, 1);
    expect(listening.brows, Brows.raised);
    expect(listening.lookY, -0.35);
  });

  test('scene layouts match the Swift ones', () {
    final popover = SceneLayout.popover(360, 178);
    expect(popover.ground, 154);
    expect(popover.scale, 1.12);
    expect(popover.petHome, closeTo(97.2, 1e-9));
    final phone = SceneLayout.phone(const Size(390, 300));
    expect(phone.ground, 274);
    expect(phone.scale, 1.55);
  });
}
