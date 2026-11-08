// Live previews in Settings, drawn by mochi_art from the settings as they change: the pet alone (the sidebar's pet
// card, About) and the room (Characters, Fun), with today's holiday decorations and costumes.

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';

import '../../core/desktop_settings.dart';

/// A calm, friendly pose for still previews: a moment into the idle loop, or the neutral pose before the animations
/// have loaded.
PetPose previewPetPose(PoseLibrary? library) => library?.petTrack(PetAnimation.idle)?.at(0.8) ?? PetPose();

CompanionPose previewCompanionPose(PoseLibrary? library) =>
    library?.companionTrack(CompanionAnimation.typing)?.at(0.6) ?? library?.companionTrack(CompanionAnimation.idleAtDesk)?.at(0.6) ?? CompanionPose();

/// The pet in its coat and what it wears today.
class PetPreview extends StatelessWidget {
  const PetPreview({super.key, required this.settings, required this.now, this.library, this.fill = 0.8, this.bottomInset = 4});

  final DesktopSettings settings;
  final DateTime now;
  final PoseLibrary? library;
  final double fill;
  final double bottomInset;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      painter: PetPainter(
        pose: previewPetPose(library),
        color: settings.petColor,
        accessory: settings.wornByPet(now),
        dark: Theme.of(context).brightness == Brightness.dark,
        fill: fill,
        bottomInset: bottomInset,
      ),
      size: Size.infinite,
    ),
  );
}

/// The room as your phones show it: the theme, the companion at the desk with the desk thing, the pet, and today's
/// holiday.
class RoomPreview extends StatelessWidget {
  const RoomPreview({super.key, required this.settings, required this.now, this.library, this.label});

  final DesktopSettings settings;
  final DateTime now;
  final PoseLibrary? library;

  /// What a screen reader hears.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final holiday = settings.holidayOn(now);
    final config = SceneConfig(
      theme: settings.officeTheme,
      petColor: settings.petColor,
      petAccessory: settings.petAccessory,
      companionAccessory: settings.companionAccessory,
      deskAccessory: settings.deskAccessory,
      season: holiday,
      reducedMotion: MediaQuery.disableAnimationsOf(context),
      room: settings.room,
    );
    return Semantics(
      image: true,
      label: label,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: CustomPaint(
          painter: ScenePainter(
            config: config,
            frame: SceneFrame(pet: previewPetPose(library), companion: previewCompanionPose(library)),
            time: 100,
            dark: Theme.of(context).brightness == Brightness.dark,
            hour: now.hour,
            layout: (size) => SceneLayout.popover(size.width, size.height),
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}
