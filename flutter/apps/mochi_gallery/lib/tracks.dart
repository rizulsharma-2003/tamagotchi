// Recorded animation tracks: every Swift animation sampled at a fixed rate by
// flutter/tools/pose_export (until the pose evaluators are ported to Dart). Playback blends
// neighbouring samples, so the gallery animates smoothly at the display's frame rate.

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:mochi_art/mochi_art.dart';

/// How long a one-shot holds its last frame before the gallery plays it again.
const double _rest = 0.8;

class Track<T> {
  Track({required this.title, required this.loop, required this.length, required this.fps, required this.frames, required this.blend});

  final String title;
  final bool loop;
  final double length;
  final double fps;
  final List<T> frames;
  final T Function(T a, T b, double t) blend;

  /// The pose `seconds` into endless playback: loops wrap, one-shots rest and restart.
  T at(double seconds) {
    final local = loop ? seconds % length : (seconds % (length + _rest)).clamp(0.0, length);
    final position = local * fps;
    final index = position.floor().clamp(0, frames.length - 1);
    final next = (index + 1).clamp(0, frames.length - 1);
    return blend(frames[index], frames[next], position - position.floor());
  }

  /// Seconds into the track (for things drawn alongside it, like the laptop cursor).
  double localTime(double seconds) => loop ? seconds % length : (seconds % (length + _rest)).clamp(0.0, length);
}

class PetTrack extends Track<PetPose> {
  PetTrack({
    required this.animation,
    required this.variant,
    required super.title,
    required super.loop,
    required super.length,
    required super.fps,
    required super.frames,
  }) : super(blend: PetPose.lerp);

  final PetAnimation animation;
  final int variant;
}

class CompanionTrack extends Track<CompanionPose> {
  CompanionTrack({
    required this.animation,
    required super.title,
    required super.loop,
    required super.length,
    required super.fps,
    required super.frames,
  }) : super(blend: CompanionPose.lerp);

  final CompanionAnimation animation;
}

class SceneTrack extends Track<SceneFrame> {
  SceneTrack({required this.interaction, required super.title, required super.length, required super.fps, required super.frames})
    : super(loop: false, blend: _blendFrames);

  final InteractionID interaction;

  static SceneFrame _blendFrames(SceneFrame a, SceneFrame b, double t) => SceneFrame(
    pet: PetPose.lerp(a.pet, b.pet, t),
    companion: CompanionPose.lerp(a.companion, b.companion, t),
    props: t < 0.5 ? a.props : b.props,
    companionVisible: a.companionVisible,
    companionVelocity: a.companionVelocity + (b.companionVelocity - a.companionVelocity) * t,
    subagents: a.subagents,
  );
}

class PoseLibrary {
  PoseLibrary({required this.pet, required this.companion, required this.interactions});

  final List<PetTrack> pet;
  final List<CompanionTrack> companion;
  final List<SceneTrack> interactions;

  PetTrack petTrack(PetAnimation animation, [int variant = 0]) =>
      pet.firstWhere((t) => t.animation == animation && t.variant == variant, orElse: () => pet.first);

  CompanionTrack companionTrack(CompanionAnimation animation) =>
      companion.firstWhere((t) => t.animation == animation, orElse: () => companion.first);

  static Future<PoseLibrary> load(AssetBundle bundle) async {
    final data = await bundle.load('assets/pose_tracks.json.deflate');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return Isolate.run(() => _parse(bytes));
  }

  static PoseLibrary _parse(Uint8List packed) {
    final json = (jsonDecode(utf8.decode(ZLibDecoder(raw: true).convert(packed))) as Map).cast<String, Object?>();
    final fps = (json['fps'] as num?)?.toDouble() ?? 15;
    List<Map<String, Object?>> entries(String key) =>
        ((json[key] as List?) ?? const []).map((e) => (e as Map).cast<String, Object?>()).toList();
    List<Map<String, Object?>> frames(Map<String, Object?> e) =>
        ((e['frames'] as List?) ?? const []).map((f) => (f as Map).cast<String, Object?>()).toList();
    T named<T extends Enum>(List<T> values, Object? name) => values.firstWhere((v) => v.name == name, orElse: () => values.first);

    return PoseLibrary(
      pet: [
        for (final e in entries('pet'))
          PetTrack(
            animation: named(PetAnimation.values, e['animation']),
            variant: (e['variant'] as num?)?.toInt() ?? 0,
            title: e['title'] as String? ?? '',
            loop: e['loop'] == true,
            length: (e['length'] as num?)?.toDouble() ?? 1,
            fps: fps,
            frames: frames(e).map(PetPose.fromJson).toList(),
          ),
      ],
      companion: [
        for (final e in entries('companion'))
          CompanionTrack(
            animation: named(CompanionAnimation.values, e['animation']),
            title: e['title'] as String? ?? '',
            loop: e['loop'] == true,
            length: (e['length'] as num?)?.toDouble() ?? 1,
            fps: fps,
            frames: frames(e).map(CompanionPose.fromJson).toList(),
          ),
      ],
      interactions: [
        for (final e in entries('interactions'))
          SceneTrack(
            interaction: named(InteractionID.values, e['interaction']),
            title: e['title'] as String? ?? '',
            length: (e['length'] as num?)?.toDouble() ?? 1,
            fps: fps,
            frames: frames(e).map(SceneFrame.fromJson).toList(),
          ),
      ],
    );
  }
}
