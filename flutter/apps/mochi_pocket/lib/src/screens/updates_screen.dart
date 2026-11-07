import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/pocket_model.dart';
import '../model/updates_history.dart';
import '../services/link_opener.dart';
import '../theme.dart';
import '../voice/updates_reader.dart';
import '../widgets/agent_card.dart';
import '../widgets/clay.dart';
import 'home_screen.dart' show spokenTimeFor;

/// "Waiting for you" opened up (iOS/MochiPocket/UpdatesView.swift): everything that's waiting, then the week's earlier
/// updates by day ("Earlier today", "Yesterday", "Tuesday, 4 Nov"): what came in and when, and what you or your
/// computer marked done, where and when. Pull down to ask your computer to check again. Each update is its own small
/// clay card, in a lazily built list. "Read aloud" reads what's waiting; leaving the screen stops it, as on the iPhone.
/// With Mochi Cloud set up, an email's long-press menu has "Draft a reply…".
class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key, required this.model, required this.opener, required this.reader, required this.checkNow, this.draft});

  final PocketModel model;
  final LinkOpener opener;
  final UpdatesReader reader;
  final VoidCallback checkNow;

  /// "Draft a reply…" for an email (null: Mochi Cloud isn't set up).
  final void Function(AgentNote note)? draft;

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  PocketModel get model => widget.model;
  LinkOpener get opener => widget.opener;
  VoidCallback get checkNow => widget.checkNow;

  @override
  void dispose() {
    widget.reader.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // Leaving stops the reading at once (the iPhone's onDisappear), not after the page has slid away.
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) widget.reader.stop();
    },
    child: _screen(context),
  );

  Widget _screen(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Updates'),
      actions: [
        ListenableBuilder(
          listenable: widget.reader,
          builder: (context, _) {
            final speaking = widget.reader.speaking;
            return TextButton.icon(
              onPressed: () =>
                  widget.reader.toggle(model.waiting, talkBack: MediaQuery.accessibleNavigationOf(context), time: spokenTimeFor(context)),
              icon: Icon(speaking ? Icons.stop_circle_rounded : Icons.volume_up_rounded),
              label: Text(speaking ? 'Stop' : 'Read aloud'),
            );
          },
        ),
        const SizedBox(width: Space.s),
      ],
    ),
    body: PocketBackground(
      child: ListenableBuilder(
        listenable: model,
        builder: (context, _) {
          final rows = _rows(context);
          return RefreshIndicator(
            onRefresh: () async => checkNow(),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, Space.xl + MediaQuery.paddingOf(context).bottom),
              itemCount: rows.length,
              itemBuilder: (context, index) => rows[index],
            ),
          );
        },
      ),
    ),
  );

  /// One entry per list row: built lazily by the list, so a long week of updates stays cheap.
  List<Widget> _rows(BuildContext context) {
    final p = context.palette;
    final agent = model.agent;
    final waiting = model.waiting;
    final days = model.historyDays;
    final headline = agent?.headline;
    final looked = agent?.lookedAt;
    Widget card(Widget child, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: Space.s),
      child: ClayCard(radius: Radii.inner + 4, padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.xs, Space.xs), child: child),
    );
    return [
      if (headline != null && headline.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.l),
          child: ClayCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconTile(icon: Icons.auto_awesome_rounded, tint: p.tint),
                const SizedBox(width: Space.m),
                Expanded(child: Text(headline, style: context.type.subheadline)),
              ],
            ),
          ),
        ),
      SectionTitle(
        title: 'Waiting for you',
        action: waiting.length > 1
            ? TextButton.icon(
                onPressed: () => model.markDone(waiting.map((note) => note.id)),
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: Text('Mark all done', semanticsLabel: 'Mark all ${waiting.length} done'),
              )
            : null,
      ),
      const SizedBox(height: Space.s),
      if (agent == null)
        card(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.m),
            child: Row(
              children: [
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(width: Space.m),
                Expanded(child: Text('Waiting to hear from ${model.host.yours}…', style: context.type.footnote)),
              ],
            ),
          ),
        )
      else if (waiting.isEmpty)
        card(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.m),
            child: NoteLabel(
              text: 'Nothing waiting. ${model.petName} will tell you when something comes in.',
              icon: Icons.verified_rounded,
              tint: p.success,
            ),
          ),
        ),
      for (final note in waiting)
        card(
          key: ValueKey(note.id),
          UpdateRow(
            note: note,
            opener: opener,
            onDone: () => model.markDone([note.id]),
            onDraft: widget.draft == null ? null : () => widget.draft!(note),
          ),
        ),
      if (looked != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, 0),
          child: Text(
            'Checked by ${agent?.origin?.startsWith('cloud') == true ? 'Mochi Cloud' : model.host.yours} ${relativeTime(looked)}. Pull down to check again.',
            style: context.type.footnote,
          ),
        ),
      for (final group in days) ...[
        const SizedBox(height: Space.l),
        _DayTitle(title: dayTitle(context, group.day)),
        const SizedBox(height: Space.s),
        for (final entry in group.entries)
          card(
            key: ValueKey('history-${entry.id}'),
            UpdateRow(
              note: entry.note,
              opener: opener,
              done: model.isDone(entry.id),
              doneButton: false,
              onDone: () => model.markDone([entry.id]),
              onNotDone: () => model.markNotDone(entry.id),
              onDraft: widget.draft == null ? null : () => widget.draft!(entry.note),
              caption: _caption(context, entry),
            ),
          ),
      ],
      if (days.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, 0),
          child: Text('Press and hold an update to mark it done or not done. Updates stay here for a week.', style: context.type.footnote),
        ),
    ];
  }

  /// "Done on your Mac · 3:12 PM", "Done here · Yesterday, 9:05 AM"; for one that isn't done, when it came in.
  String _caption(BuildContext context, HistoryEntry entry) {
    final at = model.doneAt(entry.id);
    if (at == null) return 'Came in at ${clockTime(context, entry.firstSeen)}';
    final where = model.doneWhere(entry.id);
    final when = _sameDay(at, entry.firstSeen) ? clockTime(context, at) : '${_dayWord(context, at)}, ${clockTime(context, at)}';
    return '${where == null ? 'Done' : 'Done $where'} · $when';
  }

  static bool _sameDay(double a, double b) {
    final x = timeOf(a), y = timeOf(b);
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  static String _dayWord(BuildContext context, double seconds) {
    final title = dayTitle(context, timeOf(seconds));
    return title == 'Earlier today' ? 'Today' : title;
  }
}

/// A day's heading in the history: smaller and quieter than "Waiting for you", as on the iPhone.
class _DayTitle extends StatelessWidget {
  const _DayTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, 0),
    child: Semantics(
      header: true,
      child: Text(title, style: context.type.headline.copyWith(color: context.palette.inkSecondary)),
    ),
  );
}

/// The history's day headings (the iPhone's): "Earlier today", "Yesterday", else "Tuesday, 4 Nov".
String dayTitle(BuildContext context, DateTime day, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final start = DateTime(day.year, day.month, day.day);
  if (start == DateTime(today.year, today.month, today.day)) return 'Earlier today';
  if (start == DateTime(today.year, today.month, today.day - 1)) return 'Yesterday';
  const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${weekdays[start.weekday - 1]}, ${start.day} ${months[start.month - 1]}';
}
