// Port of the drawing in Sources/App/Rendering/SceneRenderer.swift. Swift's `SceneSnapshot`
// captures the world's animation state and evaluates the poses itself; the pose evaluators are
// not ported yet, so here the poses come in ready-made as a [SceneFrame] (exported from Swift,
// or later evaluated in Dart) next to the static [SceneConfig].

import 'package:flutter/painting.dart';

import 'companion_renderer.dart';
import 'drawing.dart';
import 'item_renderer.dart';
import 'model/ease.dart';
import 'model/json.dart';
import 'model/poses.dart';
import 'model/world.dart';
import 'palettes.dart';
import 'pet_renderer.dart';
import 'pixel_mascot.dart';
import 'room_decor.dart';
import 'scene_layout.dart';
import 'season_decor.dart';
import 'theme_renderer.dart';

/// The settings side of `SceneSnapshot`: what the room looks like.
class SceneConfig {
  SceneConfig({
    this.theme = OfficeTheme.cozyDesk,
    this.petColor = PetColor.cream,
    this.petAccessory,
    this.companionAccessory,
    this.deskAccessory,
    RoomLayout? room,
    this.season,
    this.reducedMotion = false,
    this.petAway = false,
  }) : room = room ?? RoomLayout();

  /// Reads the keys Swift's settings use (`theme`, `petColor`, `petAccessory`,
  /// `companionAccessory`, `deskAccessory`, `room`, `season`, `reducedMotion`, `petAway`).
  /// A missing `deskAccessory` key means the Swift default, the desk plant.
  factory SceneConfig.fromJson(Map<String, Object?> j) => SceneConfig(
    theme: enumByName(OfficeTheme.values, j['theme']) ?? OfficeTheme.cozyDesk,
    petColor: enumByName(PetColor.values, j['petColor']) ?? PetColor.cream,
    petAccessory: enumByName(Accessory.values, j['petAccessory']),
    companionAccessory: enumByName(Accessory.values, j['companionAccessory']),
    deskAccessory: j.containsKey('deskAccessory') ? enumByName(Accessory.values, j['deskAccessory']) : Accessory.plant,
    room: RoomLayout.fromJson(j['room']),
    season: enumByName(SeasonalEvent.values, j['season']),
    reducedMotion: boolean(j, 'reducedMotion', false),
    petAway: boolean(j, 'petAway', false),
  );

  OfficeTheme theme;
  PetColor petColor;

  /// The user's choices; a seasonal costume fills in when they chose nothing.
  Accessory? petAccessory;
  Accessory? companionAccessory;
  Accessory? deskAccessory;
  RoomLayout room;
  SeasonalEvent? season;
  bool reducedMotion;

  /// Mochi is out exploring the desktop.
  bool petAway;

  Accessory? get wornByPet => petAccessory ?? SeasonDecor.costume(season, Wearer.pet);
  Accessory? get wornByCompanion => companionAccessory ?? SeasonDecor.costume(season, Wearer.companion);
}

/// One frame of the scene's animation state (`SceneRenderer.Poses` plus the bits of the snapshot
/// the drawing reads).
class SceneFrame {
  SceneFrame({
    PetPose? pet,
    CompanionPose? companion,
    List<SceneProp>? props,
    this.companionVisible = true,
    this.companionVelocity = 0,
    this.subagents = 0,
  }) : pet = pet ?? PetPose(),
       companion = companion ?? CompanionPose(),
       props = props ?? [];

  factory SceneFrame.fromJson(Map<String, Object?> j) => SceneFrame(
    pet: PetPose.fromJson(asMap(j['pet'])),
    companion: CompanionPose.fromJson(asMap(j['companion'])),
    props: list(j, 'props').map(SceneProp.fromJson).toList(),
    companionVisible: boolean(j, 'companionVisible', true),
    companionVelocity: dbl(j, 'companionVelocity', 0),
    subagents: integer(j, 'subagents', 0),
  );

  PetPose pet;
  CompanionPose companion;
  List<SceneProp> props;

  /// The companion is present and not `absent`.
  bool companionVisible;

  /// How fast a script moves the mascot, in path units per second (for its stepping legs).
  double companionVelocity;

  /// Running subagents, drawn as tiny mascots hopping around the big one.
  int subagents;
}

abstract final class SceneRenderer {
  /// Draws the room, Patch at the desk, Mochi, the props and the seasonal foreground.
  /// `petOverride` lets a host adjust Mochi's pose for this frame (the iPhone's listening twirl).
  static void draw(
    SceneConfig config,
    SceneFrame frame,
    SceneLayout layout,
    GContext g, {
    double time = 0,
    bool dark = false,
    int hour = 14,
    bool showCompanion = true,
    PetPose Function(PetPose pose)? petOverride,
  }) {
    SeasonRenderContext.theme = config.theme;
    SeasonRenderContext.reducedMotion = config.reducedMotion;
    SeasonRenderContext.petColor = config.petColor;
    if (layout.background) {
      ThemeRenderer.background(config.theme, g, layout.size, layout.ground, dark: dark, time: time, hour: hour);
      SeasonDecor.drawRoom(config.season, g, layout, dark: dark, time: time);
      RoomDecor.draw(config.room, g, layout, dark: dark, time: time);
    }

    final companionVisible = showCompanion && frame.companionVisible;
    if (companionVisible || layout.emptyDesk) {
      var companion = frame.companion;
      if (!companionVisible) {
        companion = companion.copy()
          ..opacity = 0
          ..laptop.openness = 0.04
          ..laptop.screen = LaptopScreen.off
          ..effects = []
          ..held = null;
      }
      final speed = companionVisible ? frame.companionVelocity * layout.path : 0.0;
      CompanionRenderer.draw(
        companion,
        g,
        Offset(layout.companionHome, layout.ground),
        layout.scale,
        offsetX: companion.x * layout.path,
        accessory: config.wornByCompanion,
        dark: dark,
        time: time,
        speed: speed,
        reduced: config.reducedMotion,
        deskFront: (desk) => ThemeRenderer.deskFront(config.theme, desk, dark: dark, accessory: config.deskAccessory),
      );
      if (companionVisible && frame.subagents > 0) {
        final home = layout.companionHome + (CompanionRenderer.homeX + companion.x * layout.path / layout.scale) * layout.scale;
        drawHelpers(
          frame.subagents,
          Offset(home, layout.ground + CompanionRenderer.deskTop * layout.scale),
          layout.scale,
          time,
          config.reducedMotion,
          g,
        );
      }
    }

    final pet = petOverride != null ? petOverride(frame.pet) : frame.pet;
    if (!config.petAway) {
      PetRenderer.draw(
        pet,
        g,
        Offset(layout.petHome + pet.x * layout.path, layout.ground),
        layout.scale,
        PetPalette(config.petColor),
        accessory: config.wornByPet,
        dark: dark,
      );
    }

    for (final prop in frame.props) {
      final point = Offset(layout.petHome + prop.x * layout.path, layout.ground - prop.y * PetRenderer.bodyHeight * layout.scale);
      EffectRenderer.drawProp(prop, g, point, layout.scale, dark);
    }
    SeasonDecor.drawForeground(config.season, g, layout, dark: dark, time: time, reduced: config.reducedMotion);
  }

  /// Subagents are tiny mascots hopping around the big one, each on its own beat.
  static void drawHelpers(int count, Offset origin, double scale, double time, bool reduced, GContext g) {
    for (var index = 0; index < count && index < 3; index++) {
      final beat = reduced ? 0.0 : time * 2.2 + index * 1.3;
      final hop = reduced ? 0.0 : Ease.hop(Ease.fract(beat)) * 5;
      final x = origin.dx + (index - 1) * 17 * scale - 30 * scale;
      final pose = CompanionPose()
        ..eyeOpenness = Ease.blink(time + index * 1.7, seed: index + 3, period: 3.9)
        ..eyes = Ease.fract(beat) < 0.5 ? VisorEyes.normal : VisorEyes.happy
        ..leftArm = index == 1 ? 0.8 : 0
        ..rightArm = index == 1 ? 0 : 0.8;
      final options = MascotOptions(showsSpark: false, reduced: reduced);
      PixelMascot.draw(pose, g, Offset(x, origin.dy - (50 + hop) * scale), 0.95 * scale, time, options);
    }
  }
}
