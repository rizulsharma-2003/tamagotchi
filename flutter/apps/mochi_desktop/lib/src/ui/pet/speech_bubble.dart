// The speech bubble Mochi and Patch talk in (the Mac's SpeechBubbleView, W11), and the note at the top of the room (the
// world's toast: an achievement, a new friendship level, growing up).

import 'package:flutter/material.dart';
import 'package:mochi_ui/mochi_ui.dart';

/// A small clay speech bubble, at most two lines; [urgent] (Claude needs you) has a warning outline.
class MochiBubble extends StatelessWidget {
  const MochiBubble({super.key, required this.text, this.urgent = false});

  final String text;
  final bool urgent;

  static const double maxWidth = 168;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: claySurface(p, radius: 14, outline: urgent ? p.warning : null),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: context.type.caption.copyWith(color: p.ink, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// The world's note at the top of the room: a title and a line.
class SceneNote extends StatelessWidget {
  const SceneNote({super.key, required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '$title. $detail',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: claySurface(p, radius: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: context.type.caption.copyWith(color: p.ink, fontWeight: FontWeight.w800),
            ),
            Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: context.type.caption),
          ],
        ),
      ),
    );
  }
}
