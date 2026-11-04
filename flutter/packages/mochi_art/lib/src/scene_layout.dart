// `SceneLayout` from Sources/App/Rendering/SceneRenderer.swift.

import 'dart:ui';

/// Where the room's floor, Mochi's home and the companion's desk are, and the art's scale.
class SceneLayout {
  const SceneLayout({
    required this.size,
    required this.ground,
    required this.petHome,
    required this.companionHome,
    required this.scale,
    required this.background,
    required this.emptyDesk,
  });

  /// The Mac popover's room (360 × 178 at scale 1.12).
  factory SceneLayout.popover(double width, double height) => SceneLayout(
    size: Size(width, height),
    ground: height - 24,
    petHome: width * 0.27,
    companionHome: width * 0.69,
    scale: _min(1.12, height / 158),
    background: true,
    emptyDesk: true,
  );

  /// The transparent desktop pet (no background).
  factory SceneLayout.desktop(double height) {
    final scale = height / 100;
    return SceneLayout(
      size: Size(height * 2.3, height),
      ground: height - 6 * scale,
      petHome: height * 0.42,
      companionHome: height * 1.55,
      scale: scale,
      background: false,
      emptyDesk: false,
    );
  }

  /// The iPhone's room (iOS/MochiPocket/RoomView.swift): the Mac panel's room scaled up for a phone.
  factory SceneLayout.phone(Size size) => SceneLayout(
    size: size,
    ground: size.height - 26,
    petHome: size.width * 0.26,
    companionHome: size.width * 0.70,
    scale: _min(1.55, size.height / 170),
    background: true,
    emptyDesk: true,
  );

  final Size size;
  final double ground;
  final double petHome;
  final double companionHome;
  final double scale;
  final bool background;

  /// Draw the workstation even when the companion is away.
  final bool emptyDesk;

  double get path => companionHome - petHome;

  /// Mochi's hit area.
  Rect get petFrame => Rect.fromLTWH(petHome - 34 * scale, ground - 62 * scale, 68 * scale, 64 * scale);

  /// Patch's hit area (`CompanionRenderer.homeX` is 14).
  Rect get companionFrame => Rect.fromLTWH(companionHome + (14 - 32) * scale, ground - 74 * scale, 64 * scale, 54 * scale);

  static double _min(double a, double b) => a < b ? a : b;
}
