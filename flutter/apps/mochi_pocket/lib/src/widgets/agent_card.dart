import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_link/mochi_link.dart';

import '../services/link_opener.dart';
import '../theme.dart';
import 'clay.dart';

/// What's waiting for you: new mail, coming meetings and Notion tasks, as your Mac (or Mochi Cloud) last saw them
/// (iOS/MochiPocket/AgentCard.swift). The top few show here; "See all" opens every one.
class AgentCard extends StatelessWidget {
  const AgentCard({
    super.key,
    required this.pending,
    required this.waiting,
    required this.petName,
    required this.host,
    required this.opener,
    required this.markDone,
    required this.seeAll,
    required this.checkNow,
    this.checking = false,
    this.speaking = false,
    this.speak,
  });

  final AgentPending pending;

  /// The card's items you haven't marked done.
  final List<AgentNote> waiting;
  final String petName;

  /// The computer that checked, by name ("your Mac", "your PC").
  final LinkHostName host;
  final LinkOpener opener;
  final void Function(AgentNote note) markDone;
  final VoidCallback seeAll;
  final VoidCallback checkNow;
  final bool checking;

  /// Mochi is reading the card aloud.
  final bool speaking;

  /// Reads it aloud, or stops (the iPhone's speaker button).
  final VoidCallback? speak;

  static const int shown = 4;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final top = waiting.take(shown).toList();
    final headline = pending.headline;
    final looked = pending.lookedAt;
    return ClayCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  hint: 'Opens every update',
                  child: InkWell(
                    onTap: seeAll,
                    borderRadius: BorderRadius.circular(Radii.inner),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: touchTarget),
                      child: Row(
                        children: [
                          IconTile(icon: Icons.inbox_rounded, tint: p.tint),
                          const SizedBox(width: Space.s),
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(child: Text('Waiting for you', style: context.type.headline)),
                                if (waiting.isNotEmpty) ...[
                                  const SizedBox(width: Space.s),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: ShapeDecoration(shape: const StadiumBorder(), color: p.tint),
                                    child: Text(
                                      '${waiting.length}',
                                      semanticsLabel: '${waiting.length} waiting',
                                      style: context.type.footnote.copyWith(color: p.onTint, fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          ExcludeSemantics(child: Icon(Icons.chevron_right_rounded, color: p.inkSecondary)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (speak != null) ...[
                const SizedBox(width: Space.s),
                RoundIconButton(
                  icon: speaking ? Icons.stop_rounded : Icons.volume_up_rounded,
                  label: speaking ? 'Stop reading' : 'Read out loud',
                  prominent: speaking,
                  onPressed: speak!,
                ),
              ],
            ],
          ),
          if (headline != null && headline.isNotEmpty) ...[
            const SizedBox(height: Space.s),
            Text(headline, style: context.type.subheadline),
          ],
          const SizedBox(height: Space.s),
          if (top.isEmpty)
            NoteLabel(
              text: 'Nothing waiting. $petName will tell you when something comes in.',
              icon: Icons.verified_rounded,
              tint: p.success,
            )
          else
            for (final (index, note) in top.indexed) ...[
              if (index > 0) const Padding(padding: EdgeInsets.only(left: 44), child: Divider()),
              UpdateRow(key: ValueKey(note.id), note: note, opener: opener, onDone: () => markDone(note)),
            ],
          if (waiting.length > shown) ...[
            const SizedBox(height: Space.s),
            Material(
              color: p.sunken,
              borderRadius: BorderRadius.circular(Radii.inner),
              child: InkWell(
                onTap: seeAll,
                borderRadius: BorderRadius.circular(Radii.inner),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: touchTarget),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.m),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'See all ${waiting.length}',
                            style: context.type.subheadline.copyWith(color: p.tint, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: p.tint),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: Space.m),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Space.s,
            runSpacing: Space.xs,
            children: [
              if (looked != null)
                Text(
                  'Checked by ${pending.origin?.startsWith('cloud') == true ? 'Mochi Cloud' : host.yours} · ${relativeTime(looked)}',
                  style: context.type.footnote,
                ),
              OutlinedButton.icon(
                onPressed: checking ? null : checkNow,
                icon: checking
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: Text(checking ? 'Checking…' : 'Check now'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One update (iOS `UpdateRow`): who or what, the subject, Mochi's one-line gist, and where tapping it goes. With
/// [onDone], a circle marks it done (it turns green, then the row leaves). Meetings with a video link get Join; a long
/// press opens the rest (open in the browser, mark done or not done, copy).
class UpdateRow extends StatefulWidget {
  const UpdateRow({
    super.key,
    required this.note,
    required this.opener,
    this.onDone,
    this.done = false,
    this.onNotDone,
    this.doneButton = true,
    this.caption,
  });

  final AgentNote note;
  final LinkOpener opener;
  final VoidCallback? onDone;
  final VoidCallback? onNotDone;
  final bool done;

  /// The circle that marks it done. Off in the history, where marking is in the long-press menu (the iPhone's swipe).
  final bool doneButton;

  /// A line under the gist: when it came in, or where and when it was marked done (the history).
  final String? caption;

  @override
  State<UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends State<UpdateRow> {
  bool _ticked = false;

  AgentNote get note => widget.note;

  bool get _isMeeting => note.source == AgentSource.calendar && (note.link?.startsWith('https://') ?? false);

  IconData get _icon => switch (note.source) {
    AgentSource.gmail => Icons.mail_rounded,
    AgentSource.calendar => Icons.event_rounded,
    AgentSource.notion => Icons.checklist_rounded,
  };

  Color _tint(MochiPalette p) => switch (note.source) {
    AgentSource.calendar => p.tint,
    AgentSource.notion => p.indigo,
    AgentSource.gmail => note.important ? p.warning : p.inkSecondary,
  };

  void _tick() {
    if (_ticked) return;
    HapticFeedback.mediumImpact();
    setState(() => _ticked = true);
    // Let the green tick show for a moment before the row leaves (at once when animations are off).
    final pause = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 450);
    Future<void>.delayed(pause, () {
      if (mounted) widget.onDone?.call();
    });
  }

  Future<void> _open() async {
    if (note.link == null) return;
    final opened = await widget.opener.open(note);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open that link.")));
    }
  }

  void _menu() {
    final messenger = ScaffoldMessenger.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.s),
              child: Text(note.title, style: sheet.type.headline, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            if (note.link != null)
              ListTile(
                leading: Icon(note.source == AgentSource.calendar ? Icons.videocam_rounded : Icons.open_in_new_rounded),
                title: Text(switch (note.source) {
                  AgentSource.notion => 'Open in Notion',
                  AgentSource.calendar => 'Join the meeting',
                  AgentSource.gmail => 'Open in Gmail',
                }),
                onTap: () {
                  Navigator.pop(sheet);
                  _open();
                },
              ),
            if (note.source == AgentSource.gmail && note.link != null)
              ListTile(
                leading: const Icon(Icons.public_rounded),
                title: const Text('Open this email in the browser'),
                onTap: () {
                  Navigator.pop(sheet);
                  widget.opener.openInBrowser(note);
                },
              ),
            if (widget.onDone != null && !widget.done)
              ListTile(
                leading: const Icon(Icons.check_circle_outline_rounded),
                title: const Text('Mark as done'),
                onTap: () {
                  Navigator.pop(sheet);
                  widget.onDone!();
                },
              ),
            if (widget.onNotDone != null && widget.done)
              ListTile(
                leading: const Icon(Icons.undo_rounded),
                title: const Text('Mark as not done'),
                onTap: () {
                  Navigator.pop(sheet);
                  widget.onNotDone!();
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(sheet);
                Clipboard.setData(ClipboardData(text: [note.title, note.subject, note.detail].whereType<String>().join(' — ')));
                messenger.showSnackBar(const SnackBar(content: Text('Copied')));
              },
            ),
            ListTile(leading: const Icon(Icons.close_rounded), title: const Text('Close'), onTap: () => Navigator.pop(sheet)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final done = widget.done || _ticked;
    final subject = note.subject;
    final hint = note.link == null ? 'Press and hold for more' : (note.source == AgentSource.calendar ? 'Joins the meeting' : 'Opens it');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Semantics(
            button: true,
            hint: hint,
            onLongPressHint: 'More actions',
            child: InkWell(
              onTap: note.link == null ? null : _open,
              onLongPress: _menu,
              borderRadius: BorderRadius.circular(Radii.tile),
              // Done ones fade (as on the iPhone), except the line that says where and when: that stays readable.
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.s),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Opacity(
                      opacity: widget.done ? 0.6 : 1,
                      child: IconTile(icon: done ? Icons.check_rounded : _icon, tint: done ? p.success : _tint(p)),
                    ),
                    const SizedBox(width: Space.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Opacity(
                            opacity: widget.done ? 0.6 : 1,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (note.vip == true && !done) ...[
                                      Icon(Icons.star_rounded, size: 15, color: p.vip, semanticLabel: 'VIP'),
                                      const SizedBox(width: 3),
                                    ],
                                    Flexible(
                                      child: Text(
                                        note.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.type.subheadline.copyWith(
                                          fontWeight: FontWeight.w600,
                                          decoration: widget.done ? TextDecoration.lineThrough : null,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (subject != null)
                                  Text(
                                    subject,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.type.footnote.copyWith(color: p.ink, fontWeight: FontWeight.w500),
                                  ),
                                Text(note.detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: context.type.footnote),
                                if (note.due != null && note.source != AgentSource.gmail && !widget.done)
                                  Text(
                                    note.source == AgentSource.calendar
                                        ? '${note.due! < DateTime.now().millisecondsSinceEpoch / 1000 ? 'Started' : 'Starts'} '
                                              '${relativeTime(note.due!)}'
                                        : 'Due ${relativeTime(note.due!)}',
                                    style: context.type.caption.copyWith(fontWeight: FontWeight.w600),
                                  ),
                              ],
                            ),
                          ),
                          if (widget.caption != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (widget.done) ...[
                                    Padding(
                                      padding: const EdgeInsets.only(top: 1),
                                      child: ExcludeSemantics(child: Icon(Icons.check_circle_rounded, size: 14, color: p.success)),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Flexible(
                                    child: Text(
                                      widget.caption!,
                                      style: context.type.caption.copyWith(color: p.inkSecondary, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_isMeeting && !done)
          Padding(
            padding: const EdgeInsets.only(left: Space.s),
            child: FilledButton.icon(
              onPressed: _open,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(touchTarget, touchTarget),
                textStyle: context.type.label.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              icon: const Icon(Icons.videocam_rounded, size: 16),
              label: Text('Join', semanticsLabel: 'Join ${note.title}'),
            ),
          ),
        if (widget.onDone != null && !widget.done && widget.doneButton)
          Padding(
            padding: const EdgeInsets.only(left: Space.s),
            child: IconButton(
              onPressed: _tick,
              tooltip: 'Mark ${note.title} done',
              icon: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
                child: Icon(
                  _ticked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  key: ValueKey(_ticked),
                  size: 26,
                  color: _ticked ? p.success : p.inkSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
