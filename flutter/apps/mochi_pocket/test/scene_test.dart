import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/scene/pose_library.dart';
import 'package:mochi_pocket/src/scene/scene_director.dart';

void main() {
  late PoseLibrary library;

  setUpAll(() {
    library = PoseLibrary.parse(File(PoseLibrary.asset).readAsBytesSync());
  });

  test('the recorded tracks include every loop and reaction the room uses', () {
    for (final animation in [
      PetAnimation.idle,
      PetAnimation.sleep,
      PetAnimation.watch,
      PetAnimation.waveGently,
      PetAnimation.happyBounce,
      PetAnimation.concerned,
      PetAnimation.nod,
      PetAnimation.lookAround,
    ]) {
      expect(library.petTrack(animation), isNotNull, reason: animation.name);
    }
    expect(library.petVariants(PetAnimation.petted), 3);
    expect(library.petVariants(PetAnimation.play), 4);
    expect(library.petVariants(PetAnimation.treat), 4);
    for (final animation in [
      CompanionAnimation.idleAtDesk,
      CompanionAnimation.thinking,
      CompanionAnimation.typing,
      CompanionAnimation.reading,
      CompanionAnimation.searching,
      CompanionAnimation.runningCommand,
      CompanionAnimation.browsing,
      CompanionAnimation.delegating,
      CompanionAnimation.waiting,
      CompanionAnimation.sleep,
      CompanionAnimation.celebrate,
      CompanionAnimation.concerned,
      CompanionAnimation.pat,
      CompanionAnimation.nod,
    ]) {
      expect(library.companionTrack(animation), isNotNull, reason: animation.name);
    }
  });

  test('Patch works the way Claude does, as on the Mac (workLoop), and Mochi watches', () {
    final director = SceneDirector();
    const loops = {
      'think': CompanionAnimation.thinking,
      'edit': CompanionAnimation.typing,
      'read': CompanionAnimation.reading,
      'search': CompanionAnimation.searching,
      'shell': CompanionAnimation.runningCommand,
      'web': CompanionAnimation.browsing,
      'agent': CompanionAnimation.delegating,
      'other': CompanionAnimation.typing,
    };
    for (final MapEntry(key: category, value: loop) in loops.entries) {
      director.follow(ClaudeMirror(phase: 'working', category: category), time: 0);
      expect(director.companionLoop, loop, reason: category);
      expect(director.petLoop, PetAnimation.watch);
    }
    director.follow(const ClaudeMirror(phase: 'waiting'), time: 0);
    expect(director.companionLoop, CompanionAnimation.waiting);
    expect(director.petLoop, PetAnimation.waveGently);
    director.follow(null, time: 0);
    expect(director.companionLoop, CompanionAnimation.idleAtDesk);
    expect(director.petLoop, PetAnimation.idle);
  });

  test('both sleep while the Mac rests', () {
    final director = SceneDirector()..follow(const ClaudeMirror(phase: 'working', resting: true), time: 0);
    expect(director.petLoop, PetAnimation.sleep);
    expect(director.companionLoop, CompanionAnimation.sleep);
  });

  test('a finished turn gets a happy bounce and a celebration, once; a failed one a worried look', () {
    final director = SceneDirector()..follow(const ClaudeMirror(phase: 'working'), time: 0);
    expect(director.petShot, isNull, reason: 'the first state seen is not a change');
    director.follow(const ClaudeMirror(phase: 'done'), time: 5);
    expect(director.petShot?.animation, PetAnimation.happyBounce);
    expect(director.companionShot?.animation, CompanionAnimation.celebrate);
    director.petShot = null;
    director.follow(const ClaudeMirror(phase: 'done'), time: 6);
    expect(director.petShot, isNull);
    director.follow(const ClaudeMirror(phase: 'error'), time: 7);
    expect(director.petShot?.animation, PetAnimation.concerned);
  });

  test('a pet plays once over the loop, then the loop comes back; news about a request does not cut it short', () {
    final director = SceneDirector(random: Random(1))..follow(const ClaudeMirror(phase: 'working', category: 'edit'), time: 0);
    director.cue(PetCue.pet, time: 10);
    expect(director.petShot?.animation, PetAnimation.petted);
    director.cue(PetCue.working, time: 11);
    expect(director.petShot?.animation, PetAnimation.petted);
    final during = director.poses(library, 11);
    final petted = library.petTrack(PetAnimation.petted, director.petShot!.variant)!;
    expect(during.pet.toJson(), petted.at(1).toJson());
    final after = director.poses(library, 10 + petted.length + 0.5);
    expect(director.petShot, isNull);
    expect(after.pet.toJson(), library.petTrack(PetAnimation.watch)!.at(10 + petted.length + 0.5).toJson());
    director.cue(PetCue.failed, time: 30);
    expect(director.petShot?.animation, PetAnimation.concerned);
  });

  test('with animations removed, Mochi is calmer but not frozen: half speed, a third of the movement', () {
    final track = library.petTrack(PetAnimation.watch)!;
    final rest = track.at(0).toJson(), full = track.at(1.2).toJson();
    final calm = SceneDirector.calmed(track, 2.4, calm: true).toJson();
    expect(calm, PetPose.lerp(track.at(0), track.at(1.2), SceneDirector.calmAmount).toJson());
    double moved(Map<String, Object?> pose) => [
      for (final key in rest.keys)
        if (rest[key] is num && pose[key] is num) ((pose[key]! as num) - (rest[key]! as num)).abs(),
    ].fold(0.0, (a, b) => a + b);
    expect(moved(full), greaterThan(0));
    expect(moved(calm), closeTo(moved(full) * SceneDirector.calmAmount, moved(full) * 0.05));
    expect(SceneDirector.calmed(track, 3.0, calm: true).toJson(), isNot(calm), reason: 'still alive');
    final director = SceneDirector()..follow(const ClaudeMirror(phase: 'working'), time: 0);
    expect(director.poses(library, 2.4, calm: true).pet.toJson(), calm);
  });

  test('without the recordings everyone stands still in the default pose', () {
    final poses = SceneDirector().poses(null, 3);
    expect(poses.pet.toJson(), PetPose().toJson());
    expect(poses.companion.toJson(), CompanionPose().toJson());
  });
}
