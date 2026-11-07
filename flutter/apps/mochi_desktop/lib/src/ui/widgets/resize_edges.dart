import 'package:flutter/material.dart';

import '../shell.dart';

/// Grab handles along the edges and corners of a window that has no frame of its own: the pointer shows the resize
/// cursor there, and a drag starts Windows' own resize from that edge ([onResize]). Invisible, and [thickness] wide so
/// it never covers the window's controls.
class ResizeEdges extends StatelessWidget {
  const ResizeEdges({super.key, required this.onResize, required this.child, this.thickness = 6, this.corner = 14});

  final ValueChanged<WindowEdge> onResize;
  final Widget child;
  final double thickness;
  final double corner;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: child),
      // Sides first, corners last so a corner wins where they meet.
      _handle(WindowEdge.top, top: 0, left: corner, right: corner, height: thickness),
      _handle(WindowEdge.bottom, bottom: 0, left: corner, right: corner, height: thickness),
      _handle(WindowEdge.left, left: 0, top: corner, bottom: corner, width: thickness),
      _handle(WindowEdge.right, right: 0, top: corner, bottom: corner, width: thickness),
      _handle(WindowEdge.topLeft, top: 0, left: 0, width: corner, height: corner),
      _handle(WindowEdge.topRight, top: 0, right: 0, width: corner, height: corner),
      _handle(WindowEdge.bottomLeft, bottom: 0, left: 0, width: corner, height: corner),
      _handle(WindowEdge.bottomRight, bottom: 0, right: 0, width: corner, height: corner),
    ],
  );

  Widget _handle(WindowEdge edge, {double? top, double? bottom, double? left, double? right, double? width, double? height}) {
    // A corner is only grabbable along its outer border (thickness wide), so the window's own controls stay
    // clickable inside it.
    final isCorner = width == corner && height == corner;
    final region = MouseRegion(
      cursor: cursorFor(edge),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onResize(edge),
        child: const SizedBox.expand(),
      ),
    );
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      width: width,
      height: height,
      child: isCorner ? _CornerBorder(edge: edge, thickness: thickness, child: region) : region,
    );
  }

  /// The resize cursor for [edge].
  static MouseCursor cursorFor(WindowEdge edge) => switch (edge) {
    WindowEdge.top || WindowEdge.bottom => SystemMouseCursors.resizeUpDown,
    WindowEdge.left || WindowEdge.right => SystemMouseCursors.resizeLeftRight,
    WindowEdge.topLeft || WindowEdge.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    WindowEdge.topRight || WindowEdge.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
  };
}

/// Keeps only an L-shaped strip of a corner handle (its two outer borders) hit-testable.
class _CornerBorder extends StatelessWidget {
  const _CornerBorder({required this.edge, required this.thickness, required this.child});

  final WindowEdge edge;
  final double thickness;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final top = edge == WindowEdge.topLeft || edge == WindowEdge.topRight;
    final left = edge == WindowEdge.topLeft || edge == WindowEdge.bottomLeft;
    return Stack(
      children: [
        Positioned(top: top ? 0 : null, bottom: top ? null : 0, left: 0, right: 0, height: thickness, child: child),
        Positioned(left: left ? 0 : null, right: left ? null : 0, top: 0, bottom: 0, width: thickness, child: child),
      ],
    );
  }
}
