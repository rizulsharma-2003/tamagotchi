// The palettes from Sources/App/Rendering/Drawing.swift.

import 'dart:ui';

import 'drawing.dart';
import 'model/poses.dart';
import 'model/world.dart';

/// Colours for the pet's coat.
class PetPalette {
  const PetPalette._({
    required this.body,
    required this.light,
    required this.outline,
    required this.innerEar,
    required this.blush,
    required this.eye,
    required this.eyeHighlight,
    required this.foot,
  });

  factory PetPalette(PetColor color) => switch (color) {
    PetColor.cream => _make(0xFFE2C2, 0xFFF4E6, 0xD99D6C, 0xFFB9A6, 0xFF9A9A, 0xF4C9A0),
    PetColor.peach => _make(0xFFC6AE, 0xFFE5D9, 0xD98366, 0xFF9F8C, 0xFF7F86, 0xF2A88E),
    PetColor.mint => _make(0xBDEBD4, 0xE6FBF0, 0x6FB794, 0xFFC2B8, 0xFF9DA0, 0x9ED9BC),
    PetColor.sky => _make(0xC2DEF8, 0xE9F3FE, 0x6E9DD0, 0xFFC4C7, 0xFF9FB0, 0xA3C6EC),
    PetColor.lavender => _make(0xDCCFF6, 0xF1ECFD, 0x9886CF, 0xFFC0D6, 0xFF9DC2, 0xC4B3EC),
    PetColor.cocoa => _make(0xC99B78, 0xE3C1A5, 0x87593C, 0xF0A994, 0xF38C80, 0xB08262),
    PetColor.midnight => _make(0x4D5387, 0x7178B0, 0x2A2E57, 0xC98BC4, 0xE086B3, 0x3D4273, eye: 0xFFF1D2, eyeHighlight: 0x2A2E57),
  };

  static PetPalette _make(
    int body,
    int light,
    int outline,
    int innerEar,
    int blush,
    int foot, {
    int eye = 0x2C2234,
    int eyeHighlight = 0xFFFFFF,
  }) => PetPalette._(
    body: hex(body),
    light: hex(light),
    outline: hex(outline),
    innerEar: hex(innerEar),
    blush: hex(blush),
    eye: hex(eye),
    eyeHighlight: hex(eyeHighlight),
    foot: hex(foot),
  );

  final Color body, light, outline, innerEar, blush, eye, eyeHighlight, foot;
}

/// Patch's fixed colours: warm clay with a dark glass visor.
abstract final class CompanionPalette {
  static final Color head = hex(0xE8916A);
  static final Color headLight = hex(0xF6B994);
  static final Color outline = hex(0xA8552F);
  static final Color body = hex(0xD97F58);
  static final Color visor = hex(0x2A2232);
  static final Color visorEdge = hex(0x3D3247);
  static final Color eye = hex(0xFFE9C4);
  static final Color bolt = hex(0xC46C46);
  static final Color laptop = hex(0xB9B2C2);
  static final Color laptopDark = hex(0x8C849A);

  static Color antenna(AntennaTint tint) => switch (tint) {
    AntennaTint.calm => hex(0xFFD38A),
    AntennaTint.working => hex(0x7FE3CB),
    AntennaTint.attention => hex(0xFFB24A),
    AntennaTint.alert => hex(0xFF7B6E),
    AntennaTint.off => hex(0x8C8496),
  };
}

abstract final class ConfettiPalette {
  static final List<Color> colors = [hex(0xFF8FA3), hex(0x7FD6C2), hex(0xFFD166), hex(0x9C8CFF)];
}
