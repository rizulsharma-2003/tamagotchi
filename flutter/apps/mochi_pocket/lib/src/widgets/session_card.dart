import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';

import '../theme.dart';
import 'clay.dart';

/// One Claude session on the Mac (iOS/MochiPocket/SessionCard.swift): what it's doing, Claude's summary of its last
/// turn and the files it changed, with a reply that goes to that session.
class SessionCard extends StatefulWidget {
  const SessionCard({super.key, required this.card, required this.send});

  final PhoneSessionCard card;
  final void Function(String text) send;

  @override
  State<SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<SessionCard> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _replying = false;

  PhoneSessionCard get card => widget.card;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startReplying([String? suggestion]) {
    setState(() {
      if (suggestion != null) _text.text = suggestion;
      _replying = true;
    });
    _focus.requestFocus();
  }

  void _cancel() => setState(() {
    _replying = false;
    _text.clear();
    _focus.unfocus();
  });

  void _submit() {
    final words = _text.text.trim();
    if (words.isEmpty) return;
    widget.send(words);
    _text.clear();
    _focus.unfocus();
    setState(() => _replying = false);
  }

  String get _label => switch (card.phase) {
    'working' => 'Working',
    'waiting' => 'Needs you',
    'done' => 'Finished',
    'error' => 'Hit a snag',
    _ => 'Idle',
  };

  IconData get _icon => switch (card.phase) {
    'working' => Icons.settings_suggest_rounded,
    'waiting' => Icons.back_hand_rounded,
    'done' => Icons.check_circle_rounded,
    'error' => Icons.warning_rounded,
    _ => Icons.bedtime_rounded,
  };

  Color _tint(MochiPalette p) => switch (card.phase) {
    'working' => p.tint,
    'waiting' => p.warning,
    'done' => p.success,
    'error' => p.danger,
    _ => p.inkSecondary,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final summary = card.summary;
    final finished = card.finishedAt;
    final session = summary?.session;
    final tint = _tint(p);
    return ClayCard(
      child: AnimatedSize(
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 250),
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(icon: _icon, tint: tint),
                const SizedBox(width: Space.s),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(card.project, style: context.type.headline, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: Space.xs),
                // The status stays short; the project name gets the rest of the line.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Tag(text: _label, tint: tint),
                ),
              ],
            ),
            const SizedBox(height: Space.m),
            if (summary != null) ...[
              Text(summary.done, style: context.type.subheadline),
              if (session != null && session.isNotEmpty) ...[
                const SizedBox(height: Space.s),
                NoteLabel(text: session, icon: Icons.notes_rounded),
              ],
              if (card.files.isNotEmpty) ...[const SizedBox(height: Space.s), _files(p)],
              if (finished != null) ...[
                const SizedBox(height: Space.s),
                Text('Finished ${relativeTime(finished)}', style: context.type.footnote),
              ],
            ] else
              Text(
                card.phase == 'working'
                    ? 'Claude is working — a summary comes when it finishes.'
                    : 'A summary comes when Claude finishes its next turn.',
                style: context.type.footnote,
              ),
            const SizedBox(height: Space.m),
            if (_replying) _replyField(p) else _actions(p, summary?.next ?? const []),
          ],
        ),
      ),
    );
  }

  Widget _files(MochiPalette p) => Semantics(
    label: 'Changed files: ${card.files.join(', ')}',
    excludeSemantics: true,
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final file in card.files)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: ShapeDecoration(shape: const StadiumBorder(), color: p.sunken),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.description_outlined, size: 13, color: p.ink),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    file,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: p.ink),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  /// Suggested replies wrap onto more lines rather than hiding off the edge; Reply stays at the end.
  Widget _actions(MochiPalette p, List<String> suggestions) => SizedBox(
    width: double.infinity,
    child: Wrap(
      spacing: Space.s,
      runSpacing: Space.xs,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final suggestion in suggestions)
          Semantics(
            hint: 'Starts a reply with this',
            child: ClayPress(
              onTap: () => _startReplying(suggestion),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: touchTarget),
                child: Center(
                  widthFactor: 1,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: ShapeDecoration(shape: const StadiumBorder(), color: p.sunken),
                    child: Text(
                      suggestion,
                      style: context.type.footnote.copyWith(color: p.tint, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
          ),
        FilledButton.icon(onPressed: _startReplying, icon: const Icon(Icons.reply_rounded, size: 18), label: const Text('Reply')),
      ],
    ),
  );

  Widget _replyField(MochiPalette p) => PopScope(
    // Back closes the reply first, as Cancel does.
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _cancel();
    },
    child: Container(
      constraints: const BoxConstraints(minHeight: touchTarget),
      decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(Radii.inner)),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _text,
              focusNode: _focus,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              onChanged: (_) => setState(() {}),
              style: context.type.body,
              decoration: InputDecoration(hintText: 'Tell Claude what to do next', fillColor: p.sunken.withValues(alpha: 0)),
            ),
          ),
          IconButton(
            onPressed: _text.text.trim().isEmpty ? null : _submit,
            tooltip: 'Send to Claude',
            color: p.tint,
            icon: const Icon(Icons.send_rounded),
          ),
          IconButton(onPressed: _cancel, tooltip: 'Cancel reply', color: p.inkSecondary, icon: const Icon(Icons.close_rounded, size: 20)),
        ],
      ),
    ),
  );
}
