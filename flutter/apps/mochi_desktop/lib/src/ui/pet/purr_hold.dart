// Press and hold Mochi to keep it purring (W21): the Mac's 0.3-second hold. A click still pets (or opens the popover on
// the taskbar), and a drag that starts before the hold still moves Mochi; once it purrs, moving doesn't drag it.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../core/purr.dart';

class PurrHold extends StatefulWidget {
  const PurrHold({super.key, required this.purr, required this.child});

  final PurrSession purr;
  final Widget child;

  /// How long a press is held before Mochi purrs (the Mac's).
  static const Duration hold = Duration(milliseconds: 300);

  @override
  State<PurrHold> createState() => _PurrHoldState();
}

class _PurrHoldState extends State<PurrHold> {
  bool _holding = false;

  void _begin() {
    _holding = true;
    widget.purr.begin();
  }

  void _end() {
    if (!_holding) return;
    _holding = false;
    widget.purr.end();
  }

  @override
  void dispose() {
    _end();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    gestures: {
      LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
        () => LongPressGestureRecognizer(duration: PurrHold.hold, debugOwner: this),
        (recognizer) => recognizer
          ..onLongPressStart = ((_) => _begin())
          ..onLongPressEnd = ((_) => _end())
          ..onLongPressCancel = _end,
      ),
    },
    child: widget.child,
  );
}
