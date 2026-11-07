// The drawing half of Sources/App/Features/Seasons/SeasonDecor.swift. The rules half (the costume for a holiday, the
// candles on the cake) is mochi_world's `SeasonDecor`, re-exported here with `Wearer`.

import 'package:flutter/painting.dart';

import 'drawing.dart';
import 'model/world.dart';
import 'scene_layout.dart';
import 'season_art.dart';

export 'package:mochi_world/mochi_world.dart' show SeasonDecor, Wearer;

/// What per-frame drawing needs but isn't handed (the theme, Reduced Motion, the menu-bar switch,
/// the pet's colour for the photo on the wall). `SceneRenderer.draw` keeps it up to date.
abstract final class SeasonRenderContext {
  static OfficeTheme theme = OfficeTheme.cozyDesk;
  static bool reducedMotion = false;
  static bool decorateMenuBar = true;

  /// The year New Year's decorations welcome.
  static int newYear = 2027;

  /// Candles on the birthday cake.
  static int candles = 3;

  /// The pet's coat, for the framed photo in the room.
  static PetColor petColor = PetColor.cream;
}

/// Draws a holiday's decorations (Swift `SeasonDecor`'s drawing functions; which costume goes with which holiday is
/// mochi_world's `SeasonDecor.costume`).
abstract final class SeasonDecorArt {
  /// Room decorations, drawn over the theme background and behind the characters.
  static void drawRoom(SeasonalEvent? event, GContext g, SceneLayout layout, {bool dark = false, double time = 0}) {
    if (event == null || !layout.background) return;
    SeasonArt.room(event, g, layout, dark: dark, time: time, theme: SeasonRenderContext.theme, reduced: SeasonRenderContext.reducedMotion);
  }

  /// Weather and sky effects in front of everything (snow, fireworks).
  static void drawForeground(
    SeasonalEvent? event,
    GContext g,
    SceneLayout layout, {
    bool dark = false,
    double time = 0,
    bool reduced = false,
  }) {
    // Only the room: on the transparent desktop pet a patch of snow would look like a box.
    if (event == null || !layout.background || reduced) return;
    SeasonArt.foreground(event, g, layout, dark: dark, time: time);
  }

  /// A tiny decoration beside the menu-bar bed (a pumpkin, a diya, a little tree).
  static void drawMenuBarAccent(SeasonalEvent? event, GContext g, Offset point, double scale, {bool dark = false}) {
    if (event == null || !SeasonRenderContext.decorateMenuBar) return;
    SeasonArt.menuBarAccent(event, g, Offset(point.dx + 15.5 * scale, point.dy), scale, dark: dark);
  }
}
