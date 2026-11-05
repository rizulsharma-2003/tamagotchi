// Recorded pose tracks: the same file format and playback as mochi_gallery's tracks.dart and mochi_pocket's
// pose_library.dart, shared here so new apps don't copy them again.

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'model/poses.dart';
import 'model/world.dart';

/// One recorded animation. Playback blends neighbouring samples, so it animates smoothly at any frame rate.
class PoseTrack<T> {
  PoseTrack({required this.loop, required this.length, required this.fps, required this.frames, required this.blend});

  final bool loop;

  /// Seconds.
  final double length;
  final double fps;
  final List<T> frames;
  final T Function(T a, T b, double t) blend;

  /// The pose [seconds] into the track: a loop wraps, a one-shot holds its last frame.
  T at(double seconds) {
    final local = loop ? seconds % length : seconds.clamp(0.0, length);
    final position = local * fps;
    final index = position.floor().clamp(0, frames.length - 1);
    final next = (index + 1).clamp(0, frames.length - 1);
    return blend(frames[index], frames[next], position - position.floor());
  }

  /// With animations turned off, everyone keeps living, calmer: loops play at [calmSpeed] and every pose moves only
  /// [calmAmount] of the way from the track's resting frame (as the iPhone calms Mochi under Reduce Motion instead of
  /// freezing it). A one-shot keeps its timing, so it still ends on time.
  T calmed(double seconds, {required bool calm, bool oneShot = false}) {
    if (!calm) return at(seconds);
    return blend(at(0), at(oneShot ? seconds : seconds * calmSpeed), calmAmount);
  }

  static const double calmSpeed = 0.5;
  static const double calmAmount = 0.35;
}

class PetTrack extends PoseTrack<PetPose> {
  PetTrack({
    required this.animation,
    required this.variant,
    required super.loop,
    required super.length,
    required super.fps,
    required super.frames,
  }) : super(blend: PetPose.lerp);

  final PetAnimation animation;
  final int variant;
}

class CompanionTrack extends PoseTrack<CompanionPose> {
  CompanionTrack({required this.animation, required super.loop, required super.length, required super.fps, required super.frames})
    : super(blend: CompanionPose.lerp);

  final CompanionAnimation animation;
}

/// Every recorded track.
class PoseLibrary {
  PoseLibrary({required this.pet, required this.companion});

  final List<PetTrack> pet;
  final List<CompanionTrack> companion;

  /// The track for [animation] (and [variant], when it has several), or null when it wasn't recorded.
  PetTrack? petTrack(PetAnimation animation, [int variant = 0]) {
    PetTrack? first;
    for (final track in pet) {
      if (track.animation != animation) continue;
      if (track.variant == variant) return track;
      first ??= track;
    }
    return first;
  }

  int petVariants(PetAnimation animation) => pet.where((track) => track.animation == animation).length;

  CompanionTrack? companionTrack(CompanionAnimation animation) {
    for (final track in companion) {
      if (track.animation == animation) return track;
    }
    return null;
  }

  /// Loads and parses [asset] (off the UI isolate).
  static Future<PoseLibrary> load(AssetBundle bundle, String asset) async {
    final data = await bundle.load(asset);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return Isolate.run(() => parse(bytes));
  }

  /// Raw-deflated JSON: `{fps, pet: [{animation, variant, loop, length, frames}], companion: […]}`. Animations this
  /// version doesn't know are skipped.
  static PoseLibrary parse(Uint8List packed) {
    final json = (jsonDecode(utf8.decode(ZLibDecoder(raw: true).convert(packed))) as Map).cast<String, Object?>();
    final fps = (json['fps'] as num?)?.toDouble() ?? 15;
    List<Map<String, Object?>> entries(String key) =>
        ((json[key] as List?) ?? const []).map((e) => (e as Map).cast<String, Object?>()).toList();
    List<Map<String, Object?>> frames(Map<String, Object?> e) =>
        ((e['frames'] as List?) ?? const []).map((f) => (f as Map).cast<String, Object?>()).toList();
    T? named<T extends Enum>(List<T> values, Object? name) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      return null;
    }

    return PoseLibrary(
      pet: [
        for (final e in entries('pet'))
          if (named(PetAnimation.values, e['animation']) case final animation?)
            PetTrack(
              animation: animation,
              variant: (e['variant'] as num?)?.toInt() ?? 0,
              loop: e['loop'] == true,
              length: (e['length'] as num?)?.toDouble() ?? 1,
              fps: fps,
              frames: frames(e).map(PetPose.fromJson).toList(),
            ),
      ],
      companion: [
        for (final e in entries('companion'))
          if (named(CompanionAnimation.values, e['animation']) case final animation?)
            CompanionTrack(
              animation: animation,
              loop: e['loop'] == true,
              length: (e['length'] as num?)?.toDouble() ?? 1,
              fps: fps,
              frames: frames(e).map(CompanionPose.fromJson).toList(),
            ),
      ],
    );
  }
}
