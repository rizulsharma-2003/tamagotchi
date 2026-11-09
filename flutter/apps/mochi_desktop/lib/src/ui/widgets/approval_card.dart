import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/ask_brain.dart';

/// Mochi asks before a message goes to one of your Claude sessions (the Mac's approval card): the session and its
/// project, the full text, and two choices. Only Send sends; Don't send, Escape, the time running out or quitting all
/// decline.
///
/// Keyboard: the card takes the focus on "Don't send" (so a stray Return can't send), Tab reaches Send, Escape declines,
/// Ctrl+Return sends. A screen reader announces the card with the session and the whole message when it appears.
class ApprovalCard extends StatefulWidget {
  const ApprovalCard({super.key, required this.approval, required this.pet, required this.onSend, required this.onDecline});

  final AskApproval approval;
  final String pet;
  final VoidCallback onSend;
  final VoidCallback onDecline;

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  final FocusNode _decline = FocusNode(debugLabel: "Don't send");
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _decline.requestFocus();
    });
  }

  @override
  void dispose() {
    _decline.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final approval = widget.approval;
    final target = approval.project ?? approval.target;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDecline,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): widget.onSend,
      },
      child: FocusTraversalGroup(
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          liveRegion: true,
          label: '${widget.pet} wants to send a message to your Claude session $target. The message is: ${approval.message}',
          child: ClayCard(
            padding: const EdgeInsets.all(Space.m),
            outline: p.tint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.send_rounded, size: 16, color: p.tint),
                    const SizedBox(width: Space.s),
                    Expanded(
                      child: Text(
                        'Send to Claude · ${approval.title}',
                        style: context.type.footnote.copyWith(fontWeight: FontWeight.w700, color: p.ink),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.s),
                // The whole message, always: a long one scrolls.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      child: SelectableText(approval.message, style: context.type.subheadline.copyWith(color: p.ink)),
                    ),
                  ),
                ),
                const SizedBox(height: Space.s),
                Text(
                  'It arrives as “Message from @mochi”. Your permission prompts still apply there.',
                  style: context.type.footnote.copyWith(color: p.inkSecondary),
                ),
                const SizedBox(height: Space.s),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Space.s,
                  runSpacing: Space.s,
                  children: [
                    Semantics(
                      button: true,
                      enabled: true,
                      focusable: true,
                      label: "Don't send this message",
                      onTap: widget.onDecline,
                      excludeSemantics: true,
                      child: OutlinedButton(focusNode: _decline, onPressed: widget.onDecline, child: const Text("Don't send")),
                    ),
                    Semantics(
                      button: true,
                      enabled: true,
                      focusable: true,
                      label: 'Send this message to $target',
                      onTap: widget.onSend,
                      excludeSemantics: true,
                      child: FilledButton(onPressed: widget.onSend, child: const Text('Send')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
