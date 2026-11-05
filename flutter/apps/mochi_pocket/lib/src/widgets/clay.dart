// The building blocks of every screen, as on the iPhone (Theme.swift, ContentView.swift): the clay surface and
// card, the warm backdrop, round icon buttons, icon tiles, tags, section titles, status pills and the big actions.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// The clay surface behind a card: solid fill, a hairline rim, a soft shadow and a contact shadow (deeper in the dark
/// theme, where a warm-brown shadow wouldn't show).
BoxDecoration claySurface(MochiPalette p, {double radius = Radii.card, Color? fill, Color? outline}) => BoxDecoration(
  color: fill ?? p.surface,
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: outline ?? p.stroke, width: outline == null ? 1 : 1.5),
  boxShadow: [
    BoxShadow(
      color: p.shadow.withValues(alpha: p.isDark ? 0.45 : 0.10),
      blurRadius: 16,
      offset: const Offset(0, 8),
    ),
    BoxShadow(
      color: p.shadow.withValues(alpha: p.isDark ? 0.35 : 0.06),
      blurRadius: 1.5,
      offset: const Offset(0, 1),
    ),
  ],
);

/// A Mochi card: content padded on the clay surface, full width. [outline] draws a tinted rim (the approval card).
class ClayCard extends StatelessWidget {
  const ClayCard({super.key, required this.child, this.padding = const EdgeInsets.all(Space.l), this.outline, this.radius = Radii.card});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? outline;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: claySurface(context.palette, radius: radius, outline: outline),
    child: child,
  );
}

/// The app's warm backdrop, with a soft peach glow behind the top of the screen.
class PocketBackground extends StatelessWidget {
  const PocketBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.backgroundTop, p.backgroundBottom]),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topRight,
            radius: 1.1,
            colors: [
              p.peach.withValues(alpha: p.isDark ? 0.10 : 0.18),
              p.peach.withValues(alpha: 0),
            ],
          ),
        ),
        child: child,
      ),
    );
  }
}

/// A soft press for tappable tiles: a slight squish (only a dim when animations are off), quick to respond, with a
/// light haptic tap.
class ClayPress extends StatefulWidget {
  const ClayPress({super.key, required this.child, required this.onTap, this.onLongPress, this.semanticLabel, this.selected});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;
  final bool? selected;

  @override
  State<ClayPress> createState() => _ClayPressState();
}

class _ClayPressState extends State<ClayPress> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final onTap = widget.onTap;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                onTap();
              },
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _pressed && !still ? 0.96 : 1,
          duration: still ? Duration.zero : const Duration(milliseconds: 120),
          child: AnimatedOpacity(
            opacity: _pressed ? 0.8 : 1,
            duration: still ? Duration.zero : const Duration(milliseconds: 120),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// A round icon button: a 40 dp disc inside a 48 dp touch target, with a spoken name (and a long-press tooltip).
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.label, required this.onPressed, this.tint, this.prominent = false});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// Defaults to terracotta.
  final Color? tint;

  /// Filled with the tint (an "on" state).
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = tint ?? p.tint;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: ClayPress(
        onTap: onPressed,
        semanticLabel: label,
        child: SizedBox(
          width: touchTarget,
          height: touchTarget,
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, color: prominent ? color : p.sunken),
              child: Icon(icon, size: 20, color: prominent ? p.onTint : color),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small rounded tile with a filled icon: the one icon style for list rows and card headers. Decorative (the text
/// beside it says the same), so TalkBack skips it.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, required this.tint, this.size = 32});

  final IconData icon;
  final Color tint;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: context.palette.isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
      child: Icon(icon, size: size * 0.54, color: tint),
    ),
  );
}

/// A small status tag: tinted text on a faint wash of the same colour.
class Tag extends StatelessWidget {
  const Tag({super.key, required this.text, this.icon, this.tint});

  final String text;
  final IconData? icon;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final color = tint ?? context.palette.tint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: color.withValues(alpha: 0.09)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[ExcludeSemantics(child: Icon(icon, size: 13, color: color)), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.caption.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// A section title over the cards, with an optional note or action on the right. When the text is too large for
/// both on one line, the action moves under the title instead of squeezing it.
class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.title, this.note, this.action});

  final String title;
  final String? note;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final trailing = action ?? (note == null ? null : Text(note!, style: context.type.footnote.copyWith(fontWeight: FontWeight.w600)));
    final heading = Semantics(header: true, child: Text(title, style: context.type.title3));
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.s, Space.xs, 0),
      child: trailing == null
          ? Align(alignment: Alignment.centerLeft, child: heading)
          : OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              overflowAlignment: OverflowBarAlignment.start,
              spacing: Space.s,
              children: [heading, trailing],
            ),
    );
  }
}

/// A small pill under the name: whether the Mac is online, the friendship level.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, required this.icon, required this.tint});

  final String text;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: ShapeDecoration(
        color: p.surface,
        shape: StadiumBorder(side: BorderSide(color: p.stroke)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 15, color: tint)),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.footnote.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// A big clay action under the room: a coloured icon well over a dark label.
class ActionButton extends StatelessWidget {
  const ActionButton({super.key, required this.title, required this.icon, required this.tint, required this.onTap, this.selected = false});

  final String title;
  final IconData icon;
  final Color tint;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClayPress(
      onTap: onTap,
      semanticLabel: title,
      selected: selected,
      child: Container(
        constraints: const BoxConstraints(minHeight: 84),
        decoration: claySurface(p, radius: 20),
        padding: const EdgeInsets.symmetric(vertical: Space.s, horizontal: Space.xs),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? tint : tint.withValues(alpha: p.isDark ? 0.18 : 0.12),
              ),
              child: Icon(icon, size: 19, color: selected ? p.onTint : tint),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.footnote.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tinted note with an icon: hints and problems inside cards.
class NoteLabel extends StatelessWidget {
  const NoteLabel({super.key, required this.text, required this.icon, this.tint, this.textColor});

  final String text;
  final IconData icon;
  final Color? tint;
  final Color? textColor;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: ExcludeSemantics(child: Icon(icon, size: 16, color: tint ?? context.palette.inkSecondary)),
      ),
      const SizedBox(width: Space.s),
      Expanded(
        child: Text(text, style: context.type.footnote.copyWith(color: textColor)),
      ),
    ],
  );
}

/// "5 min ago", "in 2 hours", "just now" for a Unix time.
String relativeTime(double seconds, {DateTime? now}) {
  final then = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  final delta = (now ?? DateTime.now()).difference(then);
  final future = delta.isNegative;
  final span = delta.abs();
  String amount;
  if (span.inSeconds < 45) return future ? 'in a moment' : 'just now';
  if (span.inMinutes < 60) {
    final minutes = span.inSeconds < 90 ? 1 : (span.inSeconds / 60).round();
    amount = '$minutes min';
  } else if (span.inHours < 24) {
    final hours = (span.inMinutes / 60).round();
    amount = '$hours hour${hours == 1 ? '' : 's'}';
  } else {
    final days = (span.inHours / 24).round();
    if (days == 1) return future ? 'tomorrow' : 'yesterday';
    amount = '$days days';
  }
  return future ? 'in $amount' : '$amount ago';
}

/// "14:02" for a Unix time, in the phone's 24-hour or 12-hour style.
String clockTime(BuildContext context, double seconds) {
  final time = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  return MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay.fromDateTime(time), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
}
