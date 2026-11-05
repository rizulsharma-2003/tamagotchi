// The building blocks of every screen (mochi_pocket's widgets/clay.dart, iOS Theme.swift): the clay surface and card,
// the warm backdrop, a pressable that also works from the keyboard, icon tiles, tags, section titles, status pills
// and notes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

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

/// A Mochi card: content padded on the clay surface, full width. [outline] draws a tinted rim.
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

/// The warm backdrop, with a soft peach glow at the top right.
class MochiBackground extends StatelessWidget {
  const MochiBackground({super.key, required this.child, this.borderRadius});

  final Widget child;

  /// Rounds the backdrop (a frameless desktop window draws its own corners).
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.backgroundTop, p.backgroundBottom]),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
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

/// A soft press for custom tappables: a slight squish (only a dim when animations are off), and on the desktop a
/// focus ring, Enter/Space to activate, and a hand cursor.
class ClayPress extends StatefulWidget {
  const ClayPress({
    super.key,
    required this.child,
    required this.onTap,
    this.semanticLabel,
    this.selected,
    this.borderRadius = const BorderRadius.all(Radius.circular(Radii.inner)),
    this.focusNode,
    this.autofocus = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final bool? selected;

  /// The focus ring's shape.
  final BorderRadius borderRadius;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<ClayPress> createState() => _ClayPressState();
}

class _ClayPressState extends State<ClayPress> {
  bool _pressed = false;
  bool _focused = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final onTap = widget.onTap;
    final p = context.palette;
    final duration = still ? Duration.zero : const Duration(milliseconds: 120);
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: widget.selected,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      onTap: onTap,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        enabled: onTap != null,
        mouseCursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => onTap?.call())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _press(true),
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          onTap: onTap,
          child: AnimatedScale(
            scale: _pressed && !still ? 0.97 : 1,
            duration: duration,
            child: AnimatedOpacity(
              opacity: _pressed ? 0.8 : 1,
              duration: duration,
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: widget.borderRadius,
                  border: _focused ? Border.all(color: p.focus, width: 2, strokeAlign: BorderSide.strokeAlignOutside) : null,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small rounded tile with a filled icon. Decorative (the text beside it says the same), so screen readers skip it.
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
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: color.withValues(alpha: 0.10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[ExcludeSemantics(child: Icon(icon, size: 13, color: color)), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.caption.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// A section title over the cards, with an optional action on the right. When text is too large for both on one
/// line, the action moves under the title.
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

/// A small pill: whether a device is online, what Claude is doing.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, required this.icon, required this.tint});

  final String text;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: ShapeDecoration(
        color: p.surface,
        shape: StadiumBorder(side: BorderSide(color: p.stroke)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 14, color: tint)),
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
