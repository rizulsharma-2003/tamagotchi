// Small building blocks for the gallery: a shared animation clock and an animated canvas.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mochi_art/mochi_art.dart';

/// Seconds since the gallery started, ticking every frame.
class GalleryClock extends ValueNotifier<double> {
  GalleryClock(TickerProvider vsync) : super(0) {
    _ticker = vsync.createTicker((elapsed) => value = elapsed.inMicroseconds / 1e6)..start();
  }

  late final Ticker _ticker;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// Makes the clock available below it.
class ClockScope extends InheritedWidget {
  const ClockScope({super.key, required this.clock, required super.child});

  final GalleryClock clock;

  static GalleryClock of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ClockScope>()!.clock;

  @override
  bool updateShouldNotify(ClockScope oldWidget) => oldWidget.clock != clock;
}

typedef ArtDraw = void Function(GContext g, Size size, double seconds);

/// A canvas redrawn every frame with the gallery clock.
class ArtCanvas extends StatelessWidget {
  const ArtCanvas({super.key, required this.draw, this.size, this.animated = true});

  final ArtDraw draw;
  final Size? size;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final clock = ClockScope.of(context);
    final paint = CustomPaint(size: size ?? Size.zero, painter: _ArtPainter(draw, animated ? clock : null));
    return RepaintBoundary(child: size == null ? SizedBox.expand(child: paint) : paint);
  }
}

class _ArtPainter extends CustomPainter {
  _ArtPainter(this.draw, this.clock) : super(repaint: clock);

  final ArtDraw draw;
  final ValueNotifier<double>? clock;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    draw(GContext(canvas), size, clock?.value ?? 0);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArtPainter oldDelegate) => true;
}

/// A captioned tile in a grid.
class Tile extends StatelessWidget {
  const Tile({super.key, required this.label, required this.child, this.selected = false, this.onTap, this.background});

  final String label;
  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: background ?? scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            Expanded(child: child),
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
            ),
          ],
        ),
      ),
    );
  }
}

/// A labelled dropdown for an enum-like list.
class Picker<T> extends StatelessWidget {
  const Picker({super.key, required this.label, required this.value, required this.items, required this.title, required this.onChanged});

  final String label;
  final T value;
  final List<T> items;
  final String Function(T item) title;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('$label ', style: Theme.of(context).textTheme.labelMedium),
      DropdownButton<T>(
        value: value,
        isDense: true,
        items: [for (final item in items) DropdownMenuItem(value: item, child: Text(title(item)))],
        onChanged: (item) {
          if (item != null) onChanged(item);
        },
      ),
    ],
  );
}

/// A labelled switch.
class Toggle extends StatelessWidget {
  const Toggle({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      Switch(value: value, onChanged: onChanged),
    ],
  );
}
