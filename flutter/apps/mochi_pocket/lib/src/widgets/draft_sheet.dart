import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';

import '../theme.dart';
import 'clay.dart';

/// "Draft a reply" (iOS/MochiPocket/UpdatesView.swift `DraftReplySheet`): Mochi Cloud reads the email and writes a
/// reply into Gmail Drafts. It never sends anything. You can say what the reply should say, or leave it to Mochi.
/// [ask] sends the request and answers why it didn't go, or null.
Future<void> showDraftReply(BuildContext context, {required AgentNote note, required Future<String?> Function(String words) ask}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => DraftReplySheet(note: note, ask: ask),
    );

class DraftReplySheet extends StatefulWidget {
  const DraftReplySheet({super.key, required this.note, required this.ask});

  final AgentNote note;
  final Future<String?> Function(String words) ask;

  @override
  State<DraftReplySheet> createState() => _DraftReplySheetState();
}

enum _Phase { editing, asking, asked, failed }

class _DraftReplySheetState extends State<DraftReplySheet> {
  final TextEditingController _words = TextEditingController();
  _Phase _phase = _Phase.editing;
  String? _problem;
  Timer? _close;

  AgentNote get note => widget.note;

  Future<void> _draft() async {
    setState(() {
      _phase = _Phase.asking;
      _problem = null;
    });
    final problem = await widget.ask(_words.text);
    if (!mounted) return;
    setState(() {
      _phase = problem == null ? _Phase.asked : _Phase.failed;
      _problem = problem;
    });
    // It's on its way: the sheet goes by itself a moment later, as on the iPhone.
    if (problem == null) {
      _close = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  void dispose() {
    _close?.cancel();
    _words.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final busy = _phase == _Phase.asking || _phase == _Phase.asked;
    final subject = note.subject;
    return Padding(
      // Above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(header: true, child: Text('Draft a reply', style: context.type.title3)),
            const SizedBox(height: Space.m),
            Container(
              padding: const EdgeInsets.all(Space.m),
              decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(Radii.inner)),
              child: MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(note.title, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
                    if (subject != null)
                      Text(
                        subject,
                        style: context.type.footnote.copyWith(color: p.ink, fontWeight: FontWeight.w500),
                      ),
                    Text(note.detail, style: context.type.footnote),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.m),
            TextField(
              controller: _words,
              autofocus: true,
              enabled: !busy,
              minLines: 2,
              maxLines: 6,
              maxLength: 300,
              textCapitalization: TextCapitalization.sentences,
              style: context.type.body,
              decoration: const InputDecoration(hintText: 'What should it say? (optional)'),
            ),
            const SizedBox(height: Space.xs),
            Text(
              'For example “say yes, Thursday 3 pm works” or “ask for the invoice again”. Leave it empty and Mochi writes a '
              'sensible reply. It lands in Gmail Drafts: nothing is sent until you send it.',
              style: context.type.footnote,
            ),
            if (_phase == _Phase.asked || _phase == _Phase.failed) ...[
              const SizedBox(height: Space.m),
              Semantics(
                liveRegion: true,
                child: _phase == _Phase.asked
                    ? NoteLabel(
                        text: "On its way. You'll get a notification when the draft is in Gmail (about a minute).",
                        icon: Icons.check_circle_rounded,
                        tint: p.success,
                        textColor: p.ink,
                      )
                    : NoteLabel(text: _problem ?? '', icon: Icons.warning_rounded, tint: p.warning, textColor: p.ink),
              ),
            ],
            const SizedBox(height: Space.l),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: Space.s,
              overflowSpacing: Space.s,
              overflowAlignment: OverflowBarAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).maybePop(), child: Text(_phase == _Phase.asked ? 'Close' : 'Cancel')),
                if (_phase != _Phase.asked)
                  FilledButton.icon(
                    onPressed: busy || note.threadId == null ? null : _draft,
                    icon: _phase == _Phase.asking
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.edit_note_rounded, size: 20),
                    label: Text(_phase == _Phase.asking ? 'Asking…' : 'Draft It'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
