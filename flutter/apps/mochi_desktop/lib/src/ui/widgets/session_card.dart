import 'package:flutter/material.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/sessions.dart';

/// How a session's phase looks: label, icon, colour.
({String label, IconData icon, Color tint}) phaseStyle(BuildContext context, ClaudeSession session) {
  final p = context.palette;
  return switch (session.phoneSessionPhase) {
    'working' => (label: 'Working', icon: Icons.bolt_rounded, tint: p.indigo),
    'waiting' => (label: 'Needs you', icon: Icons.front_hand_rounded, tint: p.warning),
    'done' => (label: 'Finished', icon: Icons.check_circle_rounded, tint: p.success),
    'error' => (label: 'Error', icon: Icons.error_rounded, tint: p.danger),
    _ => (label: session.phase == SessionPhase.ended ? 'Ended' : 'Idle', icon: Icons.pause_circle_rounded, tint: p.inkSecondary),
  };
}

/// One Claude Code session: project, phase, what it's doing, and the summary of its last turn (when shared).
class SessionCard extends StatelessWidget {
  const SessionCard({super.key, required this.session, required this.now, this.highlighted = false});

  final ClaudeSession session;
  final DateTime now;

  /// Opened from a Windows notification about this session: outlined in Mochi's colour.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = phaseStyle(context, session);
    final summary = session.summary;
    final when = relativeTime(session.lastEventAt.millisecondsSinceEpoch / 1000, now: now);
    final status = session.statusLine(now);
    final spoken = [
      session.displayName,
      style.label,
      status,
      if (summary != null) 'Last turn: ${summary.done}',
      if (session.lastBuildTest != null) session.lastBuildTest!,
      when,
    ].join('. ');
    return MergeSemantics(
      child: Semantics(
        label: spoken,
        excludeSemantics: true,
        child: ClayCard(
          padding: const EdgeInsets.all(Space.m),
          outline: highlighted ? p.tint : (session.phoneSessionPhase == 'waiting' ? p.warning.withValues(alpha: 0.6) : null),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconTile(icon: style.icon, tint: style.tint, size: 34),
              const SizedBox(width: Space.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: Space.s,
                      runSpacing: Space.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(session.displayName, style: context.type.headline),
                        Tag(text: style.label, tint: style.tint),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(status, style: context.type.footnote),
                    if (summary != null) ...[
                      const SizedBox(height: Space.s),
                      Text(summary.done, style: context.type.subheadline),
                      if (summary.next.isNotEmpty) ...[
                        const SizedBox(height: Space.xs),
                        Wrap(
                          spacing: Space.xs,
                          runSpacing: Space.xs,
                          children: [for (final next in summary.next) Tag(text: next, icon: Icons.subdirectory_arrow_right_rounded)],
                        ),
                      ],
                    ],
                    if (session.lastBuildTest != null) ...[
                      const SizedBox(height: Space.xs),
                      Text(session.lastBuildTest!, style: context.type.caption),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Space.s),
              Text(when, style: context.type.caption),
            ],
          ),
        ),
      ),
    );
  }
}
