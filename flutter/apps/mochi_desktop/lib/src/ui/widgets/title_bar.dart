import 'package:flutter/material.dart';
import 'package:mochi_ui/mochi_ui.dart';

/// The main window's own title bar (the window is frameless): drag it to move the window; a back button on inner
/// pages; Pair, Settings and Close (to the desktop pet) on the right. Every button has a tooltip and a spoken name.
class MochiTitleBar extends StatelessWidget {
  const MochiTitleBar({
    super.key,
    required this.title,
    required this.onDragStart,
    required this.onClose,
    this.onBack,
    this.onPair,
    this.onSettings,
    this.trailing,
  });

  final String title;
  final VoidCallback onDragStart;
  final VoidCallback onClose;
  final VoidCallback? onBack;
  final VoidCallback? onPair;
  final VoidCallback? onSettings;

  /// Shown before the buttons when there's room (Settings: Claude Code's status).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => onDragStart(),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: Space.s),
        child: Row(
          children: [
            if (onBack != null)
              IconButton(
                onPressed: onBack,
                tooltip: 'Back',
                icon: Icon(Icons.arrow_back_rounded, color: p.ink),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.s),
                child: ExcludeSemantics(child: Icon(Icons.pets_rounded, size: 18, color: p.tint)),
              ),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, style: context.type.headline, overflow: TextOverflow.ellipsis),
              ),
            ),
            if (trailing != null)
              LayoutBuilder(
                builder: (context, constraints) => MediaQuery.sizeOf(context).width < 560
                    ? const SizedBox.shrink()
                    : ConstrainedBox(constraints: const BoxConstraints(maxWidth: 260), child: trailing),
              ),
            if (onPair != null)
              IconButton(
                onPressed: onPair,
                tooltip: 'Pair a phone',
                icon: Icon(Icons.qr_code_2_rounded, color: p.ink),
              ),
            if (onSettings != null)
              IconButton(
                onPressed: onSettings,
                tooltip: 'Settings',
                icon: Icon(Icons.settings_outlined, color: p.ink),
              ),
            IconButton(
              onPressed: onClose,
              tooltip: 'Close (Mochi stays on your desktop)',
              icon: Icon(Icons.close_rounded, color: p.ink),
            ),
          ],
        ),
      ),
    );
  }
}
