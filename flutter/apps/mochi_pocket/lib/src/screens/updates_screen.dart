import 'package:flutter/material.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/pocket_model.dart';
import '../services/link_opener.dart';
import '../theme.dart';
import '../voice/updates_reader.dart';
import '../widgets/agent_card.dart';
import '../widgets/clay.dart';
import 'home_screen.dart' show spokenTimeFor;

/// "Waiting for you" opened up (iOS/MochiPocket/UpdatesView.swift): everything that's waiting, then what you've
/// marked done from the same card. Pull down to ask your Mac to check again. Each update is its own small clay card,
/// in a lazily built list. "Read aloud" reads what's waiting; leaving the screen stops it, as on the iPhone.
class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key, required this.model, required this.opener, required this.reader, required this.checkNow});

  final PocketModel model;
  final LinkOpener opener;
  final UpdatesReader reader;
  final VoidCallback checkNow;

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
    final done = (agent?.items ?? const <AgentNote>[]).where((note) => model.isDone(note.id)).toList();
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
          UpdateRow(note: note, opener: opener, onDone: () => model.markDone([note.id])),
        ),
      if (looked != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, 0),
          child: Text(
            'Checked by ${agent?.origin?.startsWith('cloud') == true ? 'Mochi Cloud' : model.host.yours} ${relativeTime(looked)}. Pull down to check again.',
            style: context.type.footnote,
          ),
        ),
      if (done.isNotEmpty) ...[
        const SizedBox(height: Space.l),
        const SectionTitle(title: 'Done'),
        const SizedBox(height: Space.s),
        for (final note in done)
          card(
            key: ValueKey('done-${note.id}'),
            UpdateRow(note: note, opener: opener, done: true, onNotDone: () => model.markNotDone(note.id)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, 0),
          child: Text('Press and hold one to put it back.', style: context.type.footnote),
        ),
      ],
    ];
  }
}
