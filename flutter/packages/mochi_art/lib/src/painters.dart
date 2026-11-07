// CustomPainters over the renderers, for use in widgets.

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';

import 'companion_renderer.dart';
import 'drawing.dart';
import 'furniture_art.dart';
import 'model/poses.dart';
import 'model/world.dart';
import 'palettes.dart';
import 'pet_renderer.dart';
import 'scene_layout.dart';
import 'scene_renderer.dart';
import 'theme_renderer.dart';

/// Mochi standing on the bottom centre of the box, scaled so the body (54 units tall plus
/// room for the ears and the shadow) fills `fill` of the box's height unless [scale] is given.
class PetPainter extends CustomPainter {
  PetPainter({
    required this.pose,
    this.color = PetColor.cream,
    this.accessory,
    this.dark = false,
    this.detail = RenderDetail.standard,
    this.stage = LifeStage.grownUp,
    this.scale,
    this.fill = 0.8,
    this.bottomInset = 8,
    super.repaint,
  });

  final PetPose pose;
  final PetColor color;
  final Accessory? accessory;
  final bool dark;
  final RenderDetail detail;
  final LifeStage stage;
  final double? scale;
  final double fill;
  final double bottomInset;

  @override
  void paint(Canvas canvas, Size size) {
    final k = scale ?? size.height * fill / 66;
    final saved = PetRenderer.stage;
    PetRenderer.stage = stage;
    PetRenderer.draw(
      pose,
      GContext(canvas),
      Offset(size.width / 2, size.height - bottomInset),
      k,
      PetPalette(color),
      accessory: accessory,
      dark: dark,
      detail: detail,
    );
    PetRenderer.stage = saved;
  }

  @override
  bool shouldRepaint(PetPainter old) =>
      old.pose != pose ||
      old.color != color ||
      old.accessory != accessory ||
      old.dark != dark ||
      old.detail != detail ||
      old.stage != stage ||
      old.scale != scale;
}

/// Patch at its workstation (desk and laptop) or on its own, standing on the bottom centre.
class CompanionPainter extends CustomPainter {
  CompanionPainter({
    required this.pose,
    this.theme = OfficeTheme.cozyDesk,
    this.accessory,
    this.deskAccessory,
    this.dark = false,
    this.time = 0,
    this.workstation = true,
    this.scale,
    this.bottomInset = 6,
    super.repaint,
  });

  final CompanionPose pose;
  final OfficeTheme theme;
  final Accessory? accessory;
  final Accessory? deskAccessory;
  final bool dark;
  final double time;
  final bool workstation;
  final double? scale;
  final double bottomInset;

  @override
  void paint(Canvas canvas, Size size) {
    final k = scale ?? size.height / (workstation ? 110 : 95);
    CompanionRenderer.draw(
      pose,
      GContext(canvas),
      Offset(size.width / 2, size.height - bottomInset),
      k,
      accessory: accessory,
      dark: dark,
      time: time,
      workstation: workstation,
      deskFront: (desk) => ThemeRenderer.deskFront(theme, desk, dark: dark, accessory: deskAccessory),
    );
  }

  @override
  bool shouldRepaint(CompanionPainter old) =>
      old.pose != pose || old.theme != theme || old.accessory != accessory || old.dark != dark || old.time != time;
}

/// The whole room: theme, furniture, seasonal decorations, Patch at the desk and Mochi.
/// The layout defaults to the iPhone's (`SceneLayout.phone`), which the Android app will use.
class ScenePainter extends CustomPainter {
  ScenePainter({required this.config, required this.frame, this.time = 0, this.dark = false, this.hour = 14, this.layout, super.repaint});

  final SceneConfig config;
  final SceneFrame frame;
  final double time;
  final bool dark;
  final int hour;
  final SceneLayout Function(Size size)? layout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final l = layout?.call(size) ?? SceneLayout.phone(size);
    SceneRenderer.draw(config, frame, l, GContext(canvas), time: time, dark: dark, hour: hour);
    canvas.restore();
  }

  @override
  bool shouldRepaint(ScenePainter old) =>
      old.frame != frame || old.config != config || old.time != time || old.dark != dark || old.hour != hour;
}

/// The room drawn live, as the phones' and Windows' home screens show it: [frame] gives everyone's poses at the
/// clock's time (seconds), and it repaints whenever [clock] ticks. The layout defaults to the iPhone's.
class LiveRoomPainter extends CustomPainter {
  LiveRoomPainter({
    required this.config,
    required this.frame,
    required this.clock,
    this.dark = false,
    this.hour,
    this.calm = false,
    this.layout,
  }) : super(repaint: clock);

  final SceneConfig config;
  final SceneFrame Function(double time) frame;
  final ValueListenable<double> clock;

  /// The room's night colours, with the dark theme.
  final bool dark;

  /// The hour the window shows (null: now).
  final int? hour;

  /// Animations are off: the art's own clock runs at half speed too.
  final bool calm;
  final SceneLayout Function(Size size)? layout;

  /// The art's own clock (blinks, steam, the laptop's cursor) for [time]: well past zero, as in the gallery, and at
  /// half speed when [calm].
  static double artTime(double time, {bool calm = false}) => 100 + (calm ? time * 0.5 : time);

  @override
  void paint(Canvas canvas, Size size) {
    final time = clock.value;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    SceneRenderer.draw(
      config,
      frame(time),
      layout?.call(size) ?? SceneLayout.phone(size),
      GContext(canvas),
      time: artTime(time, calm: calm),
      dark: dark,
      hour: hour ?? DateTime.now().hour,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(LiveRoomPainter old) =>
      old.config != config || old.frame != frame || old.clock != clock || old.dark != dark || old.hour != hour || old.calm != calm;
}

/// One piece of furniture, its foot (or centre, for wall pieces and rugs) at [anchor] (defaults
/// to the bottom centre, or the centre for wall pieces and rugs).
class FurniturePainter extends CustomPainter {
  FurniturePainter({required this.id, this.dark = false, this.time = 0, this.scale = 1, this.flipped = false, super.repaint});

  final String id;
  final bool dark;
  final double time;
  final double scale;
  final bool flipped;

  @override
  void paint(Canvas canvas, Size size) {
    final kind = FurnitureCatalog.kind(id);
    final centred = kind == null || kind.placement == FurniturePlacement.wall || kind.isFlat;
    final g = GContext(canvas)
      ..translateBy(size.width / 2, centred ? size.height / 2 : size.height - 4)
      ..scaleBy(flipped ? -scale : scale, scale);
    FurnitureArt.draw(id, g, dark: dark, time: time);
  }

  @override
  bool shouldRepaint(FurniturePainter old) => old.id != id || old.dark != dark || old.time != time || old.scale != scale;
}
