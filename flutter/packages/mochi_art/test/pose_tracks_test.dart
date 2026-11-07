// The shared pose-track reader (lib/pose_tracks.dart): the file format the Swift exporter writes, playback and the
// calmer playback used when animations are off.

import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';

Uint8List pack(Map<String, Object?> json) => Uint8List.fromList(ZLibEncoder(raw: true).convert(utf8.encode(jsonEncode(json))));

void main() {
  final packed = pack({
    'fps': 2,
    'pet': [
      {
        'animation': 'idle',
        'variant': 0,
        'loop': true,
        'length': 2,
        'frames': [
          {'lookX': 0.0},
          {'lookX': 1.0},
          {'lookX': 0.0},
          {'lookX': 1.0},
        ],
      },
      {
        'animation': 'petted',
        'variant': 1,
        'loop': false,
        'length': 1,
        'frames': [
          {'lookX': 0.5},
          {'lookX': -0.5},
        ],
      },
      {'animation': 'notAnAnimationYet', 'loop': true, 'length': 1, 'frames': <Object?>[]},
    ],
    'companion': [
      {
        'animation': 'typing',
        'loop': true,
        'length': 1,
        'frames': [
          {'facing': 1},
        ],
      },
    ],
    'interactions': [
      {
        'interaction': 'highFive',
        'title': 'High five',
        'length': 1,
        'frames': [
          {
            'pet': {'x': 0.0},
            'companion': {'x': 0.0},
            'companionVisible': true,
          },
          {
            'pet': {'x': 0.4},
            'companion': {'x': -0.2},
            'props': [
              {'kind': 'sparkle', 'x': 0.5, 'y': 1},
            ],
            'companionVisible': true,
          },
        ],
      },
      {'interaction': 'notAnInteractionYet', 'length': 1, 'frames': <Object?>[]},
    ],
  });

  test('reads the exporter format and skips animations it does not know', () {
    final library = PoseLibrary.parse(packed);
    expect(library.pet, hasLength(2));
    expect(library.petTrack(PetAnimation.idle)!.loop, isTrue);
    expect(library.petTrack(PetAnimation.petted, 1)!.variant, 1);
    expect(library.petTrack(PetAnimation.petted, 7)!.variant, 1, reason: 'falls back to the first variant');
    expect(library.petVariants(PetAnimation.petted), 1);
    expect(library.petTrack(PetAnimation.sleep), isNull);
    expect(library.companionTrack(CompanionAnimation.typing)!.frames.single.facing, 1);
  });

  test('reads the interactions: whole frames, blended, holding the last one', () {
    final library = PoseLibrary.parse(packed);
    expect(library.interactions.map((track) => track.interaction), [InteractionID.highFive]);
    final track = library.interactionTrack(InteractionID.highFive)!;
    expect(track.loop, isFalse);
    expect(track.length, 1);
    final middle = track.at(0.25);
    expect(middle.pet.x, closeTo(0.2, 1e-9));
    expect(middle.companion.x, closeTo(-0.1, 1e-9));
    expect(track.at(0.1).props, isEmpty, reason: 'props switch halfway between frames');
    expect(track.at(5).props.single.kind, ScenePropKind.sparkle);
    expect(library.interactionTrack(InteractionID.welcome), isNull);
    expect(PoseLibrary.parse(pack({'fps': 2})).interactions, isEmpty, reason: 'older files have none');
  });

  test('loops wrap, one-shots hold, neighbours blend', () {
    final library = PoseLibrary.parse(packed);
    final idle = library.petTrack(PetAnimation.idle)!;
    expect(idle.at(0).lookX, closeTo(0, 1e-9));
    expect(idle.at(0.25).lookX, closeTo(0.5, 1e-9));
    expect(idle.at(2.5).lookX, closeTo(idle.at(0.5).lookX, 1e-9));
    final petted = library.petTrack(PetAnimation.petted, 1)!;
    expect(petted.at(5).lookX, closeTo(-0.5, 1e-9));
  });

  test('calm playback moves only part of the way, at half speed', () {
    final idle = PoseLibrary.parse(packed).petTrack(PetAnimation.idle)!;
    expect(idle.calmed(0.5, calm: false).lookX, closeTo(1, 1e-9));
    // At 0.5 s calm plays the 0.25 s pose (0.5), moved 35% of the way from rest (0): 0.175.
    expect(idle.calmed(0.5, calm: true).lookX, closeTo(0.175, 1e-9));
  });
}
