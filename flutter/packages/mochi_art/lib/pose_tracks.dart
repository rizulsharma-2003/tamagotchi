/// Mochi's and Patch's animations as recorded tracks (`pose_tracks.json.deflate`, written by flutter/tools/pose_export
/// from the Swift app), until the pose evaluators are ported to Dart: [PoseLibrary], [PetTrack], [CompanionTrack].
///
/// A separate library from `mochi_art.dart` so apps that still keep their own copy of these classes (mochi_pocket's
/// `scene/pose_library.dart`) don't see two of each.
library;

export 'src/pose_tracks.dart';
