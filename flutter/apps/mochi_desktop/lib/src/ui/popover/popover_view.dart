// The popover: the Mac's menu-bar popover (Sources/App/Popover/PopoverView.swift) for Windows, a flyout above the
// taskbar where Mochi is. Clicking Mochi (or Patch) on the taskbar opens it; a click outside, Escape or a click where
// Mochi was closes it, and Mochi is back on the taskbar.
//
// Top to bottom, as on the Mac: the room with Mochi and Patch; Claude Code's connection; the session (a menu to pick
// which one Mochi follows when there are several: sessions are never mixed), its status line and the result card of a
// turn that just finished; its recent events (LATE for ones that came in while Mochi wasn't running); Pet, Play and
// Treat; quick switches; and the way to Mochi's window, Ask Mochi and Settings.
//
// Under Pet, Play and Treat are the Mac's fun row (Games, Focus, Recap and Decorate so far; the rest of the Mac's row joins it as each
// is built for Windows, and nothing is shown dead), the running focus session and the friendship hearts. Its switches are the Windows ones: pause
// reactions, the desktop pet, roaming the taskbar and Patch on the taskbar.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/mochi_art.dart' show SceneLayout;
import 'package:mochi_ui/mochi_ui.dart';
import 'package:mochi_wire/mochi_wire.dart' show HookStatus;
import 'package:mochi_world/mochi_world.dart' as w show FocusPhase, FocusPhaseText, FocusStatus, focusClock;

import '../../core/desktop_settings.dart';
import '../../core/session_store.dart';
import '../../core/sessions.dart';
import '../../desktop.dart';
import '../pet/companion_director.dart';
import '../settings/panes_pet.dart' show FriendshipHearts;
import '../pet/room_view.dart';

class PopoverView extends StatelessWidget {
  const PopoverView({
    super.key,
    required this.desktop,
    required this.companion,
    required this.lastActivity,
    required this.onClose,
    required this.onOpenMain,
    required this.onAsk,
    required this.onSettings,
    required this.onSetUpClaude,
    this.onGames,
    this.onRecap,
    this.onExplore,
    this.hidePet = false,
  });

  final MochiDesktop desktop;
  final CompanionDirector companion;
  final DateTime Function() lastActivity;

  /// Escape: back to the taskbar.
  final VoidCallback onClose;
  final VoidCallback onOpenMain;
  final VoidCallback onAsk;
  final VoidCallback onSettings;

  /// Settings › Claude Code (connecting it).
  final VoidCallback onSetUpClaude;

  /// The fun row: the Games window and today's recap.
  final VoidCallback? onGames;
  final VoidCallback? onRecap;

  /// The fun row's Explore (W19: Mochi sets off along your windows; the popover closes first). Null: no such button.
  final VoidCallback? onExplore;

  /// Mochi is leaping in or out: the room without it.
  final bool hidePet;

  /// Where Mochi stands in the room (from the panel's top-left) and how big it's drawn there, for a panel [width] wide.
  static ({Offset feet, double scale}) petInRoom(double width) {
    final layout = SceneLayout.popover(width - 2, sceneHeight);
    // The panel's 1-pixel outline is outside the room.
    return (feet: Offset(1 + layout.petHome, 1 + layout.ground), scale: layout.scale);
  }

  /// The scene's height (the Mac popover's 178 points, a little shorter to leave room for the switches).
  static const double sceneHeight = 168;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pet = desktop.settings.petName;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: FocusScope(
        autofocus: true,
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: pet,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              decoration: claySurface(p, radius: 14),
              clipBehavior: Clip.antiAlias,
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  desktop.sessions,
                  desktop.settings,
                  desktop.hooks,
                  desktop.bridgeProblem,
                  companion,
                  desktop.focus,
                  desktop.room,
                ]),
                builder: (context, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: sceneHeight,
                      child: _Scene(desktop: desktop, companion: companion, lastActivity: lastActivity, hidePet: hidePet),
                    ),
                    Divider(height: 1, color: p.stroke),
                    Expanded(
                      child: Scrollbar(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.m, Space.s),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _ConnectionRow(desktop: desktop, onSetUp: onSetUpClaude),
                              const SizedBox(height: Space.m),
                              _SessionSection(desktop: desktop),
                              _ResultCard(desktop: desktop),
                              _RecentEvents(desktop: desktop),
                              const SizedBox(height: Space.s),
                              Divider(height: Space.m, color: p.stroke),
                              const SizedBox(height: Space.xs),
                              _PetControls(desktop: desktop),
                              const SizedBox(height: Space.s),
                              _FunRow(desktop: desktop, onGames: onGames, onRecap: onRecap, onExplore: onExplore),
                              const SizedBox(height: Space.s),
                              if (desktop.focus.status case final status?) ...[
                                FocusRow(desktop: desktop, status: status),
                                const SizedBox(height: Space.s),
                              ],
                              _Friendship(desktop: desktop),
                              const SizedBox(height: Space.s),
                              _Switches(settings: desktop.settings),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Divider(height: 1, color: p.stroke),
                    _Footer(pet: pet, onOpenMain: onOpenMain, onAsk: onAsk, onSettings: onSettings),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// MARK: - Scene

class _Scene extends StatelessWidget {
  const _Scene({required this.desktop, required this.companion, required this.lastActivity, this.hidePet = false});

  final MochiDesktop desktop;
  final CompanionDirector companion;
  final DateTime Function() lastActivity;
  final bool hidePet;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: RoomView(
          desktop: desktop,
          companion: companion,
          lastActivity: lastActivity,
          // The Mac popover's room.
          layout: (size) => SceneLayout.popover(size.width, size.height),
          hidePet: hidePet,
        ),
      ),
      if (desktop.settings.pauseReactions)
        Positioned(
          left: Space.s,
          top: Space.s,
          child: _Badge(text: 'PAUSED', tint: context.palette.inkSecondary),
        ),
    ],
  );
}

/// A small capsule label (the Mac's `Tag`: PAUSED, LATE).
class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.tint, this.label});

  final String text;
  final Color tint;

  /// What a screen reader says instead of the capitals.
  final String? label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label ?? text.toLowerCase(),
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: tint.withValues(alpha: 0.85)),
      child: Text(
        text,
        style: context.type.caption.copyWith(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 9.5, letterSpacing: 0.6),
      ),
    ),
  );
}

// MARK: - Connection

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({required this.desktop, required this.onSetUp});

  final MochiDesktop desktop;
  final VoidCallback onSetUp;

  /// "just now", "3 min ago".
  static String ago(DateTime then, DateTime now) {
    final seconds = now.difference(then).inSeconds;
    if (seconds < 10) return 'just now';
    if (seconds < 60) return '$seconds s ago';
    if (seconds < 3600) return '${seconds ~/ 60} min ago';
    if (seconds < 86400) return '${seconds ~/ 3600} h ago';
    return '${seconds ~/ 86400} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final last = desktop.sessions.lastEventAt;
    final (title, tint, setUp) = switch (desktop.hooks.inspection?.status) {
      HookStatus.installed when desktop.bridgeProblem.value != null => ('Claude Code can’t reach Mochi', p.danger, true),
      HookStatus.installed => (
        last == null ? 'Connected to Claude Code · no events yet' : 'Connected to Claude Code',
        last == null ? p.warning : p.success,
        false,
      ),
      HookStatus.needsUpdate => ('Claude Code’s connection needs an update', p.warning, true),
      HookStatus.unreadable => ('Claude Code needs attention', p.danger, true),
      _ => ('Claude Code isn’t connected', p.inkSecondary, true),
    };
    return MergeSemantics(
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: tint),
          ),
          const SizedBox(width: Space.s),
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.type.footnote.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: Space.xs),
          if (setUp)
            TextButton(onPressed: onSetUp, child: const Text('Set Up…'))
          else if (last != null)
            Text(ago(last, desktop.sessions.now), style: context.type.caption),
        ],
      ),
    );
  }
}

// MARK: - Session

class _SessionSection extends StatelessWidget {
  const _SessionSection({required this.desktop});

  final MochiDesktop desktop;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sessions = desktop.sessions;
    final settings = desktop.settings;
    final primary = sessions.primary;
    final now = sessions.now;
    if (primary == null) {
      final connected = desktop.hooks.connected;
      return MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              connected ? 'No Claude Code session right now' : '${settings.petName} is keeping you company',
              style: context.type.headline,
            ),
            const SizedBox(height: 2),
            Text(
              connected
                  ? 'Start Claude Code in any project and ${settings.companionName} will join.'
                  : 'Connect Claude Code to meet ${settings.companionName}, your coding companion.',
              style: context.type.footnote,
            ),
          ],
        ),
      );
    }
    final live = sessions.live;
    final title = Text(primary.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.headline);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: live.length > 1
                  ? Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: PopupMenuButton<String>(
                        tooltip: 'Choose the session ${settings.petName} follows',
                        initialValue: sessions.pinned ?? '',
                        onSelected: (id) => sessions.pin(id.isEmpty ? null : id),
                        itemBuilder: (context) => [
                          CheckedPopupMenuItem(value: '', checked: sessions.pinned == null, child: const Text('Most relevant (automatic)')),
                          const PopupMenuDivider(),
                          for (final session in live)
                            CheckedPopupMenuItem(
                              value: session.id,
                              checked: sessions.pinned == session.id,
                              child: Text(
                                '${session.displayName} — ${session.statusLine(now)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(child: title),
                            Icon(Icons.expand_more_rounded, size: 18, color: p.inkSecondary),
                          ],
                        ),
                      ),
                    )
                  : title,
            ),
            const SizedBox(width: Space.s),
            _PhaseBadge(session: primary, now: now),
          ],
        ),
        if (live.length > 1) Text('${live.length} sessions', style: context.type.caption),
        const SizedBox(height: 2),
        Text(primary.statusLine(now), style: context.type.footnote),
        if (sessions.pinned != null) Text('Pinned: ${settings.petName} follows this session', style: context.type.caption),
      ],
    );
  }
}

/// OPEN, WORKING, NEEDS YOU, DONE, API ERROR, ENDED, QUIET (the Mac's `PhaseBadge`).
class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.session, required this.now});

  final ClaudeSession session;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (text, tint) = session.isStale(now)
        ? ('QUIET', p.inkSecondary)
        : switch (session.phase) {
            SessionPhase.idle => ('OPEN', p.inkSecondary),
            SessionPhase.promptSubmitted || SessionPhase.thinking || SessionPhase.runningTool => ('WORKING', p.indigo),
            SessionPhase.waitingForUser => ('NEEDS YOU', p.warning),
            SessionPhase.turnCompleted => ('DONE', p.success),
            SessionPhase.turnFailed => ('API ERROR', p.danger),
            SessionPhase.ended => ('ENDED', p.inkSecondary),
          };
    return Semantics(
      label: text.toLowerCase(),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: ShapeDecoration(shape: const StadiumBorder(), color: tint.withValues(alpha: 0.13)),
        child: Text(
          text,
          style: context.type.caption.copyWith(color: tint, fontWeight: FontWeight.w800, fontSize: 10),
        ),
      ),
    );
  }
}

// MARK: - Result card

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.desktop});

  final MochiDesktop desktop;

  static String _time(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  static String _length(Duration duration) => duration.inHours >= 1
      ? '${duration.inHours} h ${duration.inMinutes % 60} min'
      : '${duration.inMinutes} min ${duration.inSeconds % 60} s';

  @override
  Widget build(BuildContext context) {
    final sessions = desktop.sessions;
    final session = sessions.primary;
    final done = session?.lastTurnCompletedAt;
    final now = sessions.now;
    if (session == null ||
        done == null ||
        session.phase != SessionPhase.turnCompleted ||
        now.difference(done) > const Duration(minutes: 30)) {
      return const SizedBox.shrink();
    }
    final key = '${session.id}@${done.microsecondsSinceEpoch}';
    if (sessions.dismissedResults.contains(key)) return const SizedBox.shrink();
    final p = context.palette;
    final buildTest = session.lastBuildTest;
    final passed = buildTest != null && (buildTest.contains('passed') || buildTest.contains('succeeded'));
    final started = session.turnStartedAt;
    return Padding(
      padding: const EdgeInsets.only(top: Space.s),
      child: Container(
        padding: const EdgeInsets.all(Space.s),
        decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(Radii.tile)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sports_score_rounded, size: 16, color: p.success),
                const SizedBox(width: Space.xs),
                Expanded(
                  child: Text(
                    'Turn complete · ${session.displayName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.footnote.copyWith(color: p.ink, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(_time(done), style: context.type.caption),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 14,
                  tooltip: 'Dismiss result',
                  onPressed: () => sessions.dismissResult(key),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if (session.summary != null)
              Text(
                session.summary!.done,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: context.type.footnote.copyWith(color: p.ink),
              ),
            const SizedBox(height: 2),
            if (buildTest != null)
              Row(
                children: [
                  Icon(passed ? Icons.verified_rounded : Icons.cancel_rounded, size: 14, color: passed ? p.success : p.danger),
                  const SizedBox(width: Space.xs),
                  Expanded(
                    child: Text(buildTest, style: context.type.caption.copyWith(color: passed ? p.success : p.danger)),
                  ),
                ],
              )
            else
              Text('No build or test result was received this turn.', style: context.type.caption),
            if (started != null && done.isAfter(started))
              Text('Observed turn length: ${_length(done.difference(started))}', style: context.type.caption),
          ],
        ),
      ),
    );
  }
}

// MARK: - Recent events

class _RecentEvents extends StatelessWidget {
  const _RecentEvents({required this.desktop});

  final MochiDesktop desktop;

  static IconData icon(RecentEvent event) => switch (event.kind) {
    EventKind.sessionStarted => Icons.play_circle_outline_rounded,
    EventKind.promptSubmitted => Icons.chat_bubble_outline_rounded,
    EventKind.toolStarting => switch (event.category) {
      'read' => Icons.description_outlined,
      'search' => Icons.search_rounded,
      'edit' => Icons.edit_outlined,
      'shell' => Icons.terminal_rounded,
      'web' => Icons.public_rounded,
      'agent' => Icons.group_outlined,
      'plan' => Icons.checklist_rounded,
      'ask' => Icons.help_outline_rounded,
      'mcp' => Icons.extension_outlined,
      'skill' => Icons.auto_awesome_outlined,
      _ => Icons.build_outlined,
    },
    EventKind.toolSucceeded => Icons.check_circle_outline_rounded,
    EventKind.toolFailed => event.failed ? Icons.warning_amber_rounded : Icons.stop_circle_outlined,
    EventKind.toolBatchFinished => Icons.layers_outlined,
    EventKind.permissionRequested || EventKind.attentionNeeded => Icons.back_hand_outlined,
    EventKind.permissionDenied => Icons.do_not_touch_outlined,
    EventKind.notification => Icons.notifications_none_rounded,
    EventKind.subagentStarted || EventKind.subagentStopped => Icons.people_outline_rounded,
    EventKind.turnCompleted => Icons.sports_score_rounded,
    EventKind.turnFailed => Icons.error_outline_rounded,
    EventKind.sessionEnded => Icons.stop_circle_outlined,
    EventKind.report => Icons.star_outline_rounded,
    EventKind.unknown => Icons.help_outline_rounded,
  };

  static Color tint(RecentEvent event, MochiPalette p) => switch (event.kind) {
    EventKind.toolFailed => event.failed ? p.warning : p.inkSecondary,
    EventKind.permissionRequested || EventKind.attentionNeeded => p.warning,
    EventKind.turnCompleted => p.success,
    EventKind.turnFailed => p.danger,
    _ => p.inkSecondary,
  };

  static String _clock(DateTime time) => [time.hour, time.minute, time.second].map((part) => part.toString().padLeft(2, '0')).join(':');

  @override
  Widget build(BuildContext context) {
    final session = desktop.sessions.primary;
    if (session == null) return const SizedBox.shrink();
    final events = desktop.sessions.recentFor(session.id);
    if (events.isEmpty) return const SizedBox.shrink();
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('RECENT', style: context.type.caption.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0.6, fontSize: 10)),
          ),
          const SizedBox(height: Space.xs),
          for (final event in events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: MergeSemantics(
                child: Row(
                  children: [
                    Icon(icon(event), size: 14, color: tint(event, p)),
                    const SizedBox(width: Space.s),
                    Expanded(
                      child: Text(
                        event.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.caption.copyWith(color: p.ink),
                      ),
                    ),
                    if (event.late) ...[const SizedBox(width: Space.xs), _Badge(text: 'LATE', tint: p.warning, label: 'arrived late')],
                    const SizedBox(width: Space.xs),
                    Text(_clock(event.at), style: context.type.caption.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// MARK: - Controls

class _PetControls extends StatelessWidget {
  const _PetControls({required this.desktop});

  final MochiDesktop desktop;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pet = desktop.settings.petName;
    return Row(
      children: [
        Expanded(
          child: _ControlButton(
            title: 'Pet',
            label: 'Pet $pet',
            icon: Icons.favorite_rounded,
            tint: p.pet,
            autofocus: true,
            onTap: () => desktop.interact('pet'),
          ),
        ),
        const SizedBox(width: Space.s),
        Expanded(
          child: _ControlButton(
            title: 'Play',
            label: 'Play with $pet',
            icon: Icons.sports_baseball_rounded,
            tint: p.play,
            onTap: () => desktop.interact('play'),
          ),
        ),
        const SizedBox(width: Space.s),
        Expanded(
          child: _ControlButton(
            title: 'Treat',
            label: 'Give $pet a treat',
            icon: Icons.cookie_rounded,
            tint: p.warning,
            onTap: () => desktop.interact('treat'),
          ),
        ),
        const SizedBox(width: Space.s),
        // The Mac's Milestone: a milestone you reached, celebrated (graduation the first time) and kept in the history.
        Expanded(
          child: _ControlButton(
            title: 'Milestone',
            label: 'Mark a milestone you reached',
            icon: Icons.star_rounded,
            tint: p.success,
            onTap: desktop.markMilestone,
          ),
        ),
      ],
    );
  }
}

/// The Mac's fun row: the games (and, as each comes to Windows, the rest of the Mac's row).
class _FunRow extends StatelessWidget {
  const _FunRow({required this.desktop, this.onGames, this.onRecap, this.onExplore});

  final MochiDesktop desktop;
  final VoidCallback? onGames;
  final VoidCallback? onRecap;
  final VoidCallback? onExplore;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pet = desktop.settings.petName;
    final buttons = [
      // The Mac's Explore (its popover shows Home while Mochi is out; here opening the popover brings Mochi home first).
      if (onExplore != null && desktop.settings.adventure.enabled)
        _ControlButton(
          title: 'Explore',
          label: 'Explore: $pet leaves the taskbar to explore your desktop',
          icon: Icons.directions_walk_rounded,
          tint: p.tint,
          onTap: onExplore!,
        ),
      if (onGames != null)
        _ControlButton(
          title: 'Games',
          label: 'Games: Catch the Treats and rock-paper-scissors with $pet',
          icon: Icons.sports_esports_rounded,
          tint: p.indigo,
          onTap: onGames!,
        ),
      // The Mac's Focus (Stop while a session runs): Mochi naps while you focus and wakes you for breaks.
      Tooltip(
        message: 'A focus timer: $pet naps while you work and wakes you for breaks',
        child: _ControlButton(
          title: desktop.focus.running ? 'Stop' : 'Focus',
          label: desktop.focus.running ? 'Stop focus' : 'Focus: a timer $pet naps through and wakes you for breaks',
          icon: Icons.timer_outlined,
          tint: p.indigo,
          onTap: desktop.focus.toggle,
        ),
      ),
      if (onRecap != null)
        _ControlButton(
          title: 'Recap',
          label: 'Today’s recap: what you and Claude did today',
          icon: Icons.calendar_today_rounded,
          tint: const Color(0xFFE8663D),
          onTap: onRecap!,
        ),
      _ControlButton(
        title: 'Decorate',
        label: desktop.room.isEditing ? 'Done decorating' : 'Decorate $pet’s room',
        icon: Icons.chair_rounded,
        tint: desktop.room.isEditing ? p.tint : p.warning,
        selected: desktop.room.isEditing,
        onTap: desktop.room.toggle,
      ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        for (final (index, button) in buttons.indexed) ...[if (index > 0) const SizedBox(width: Space.s), Expanded(child: button)],
      ],
    );
  }
}

/// The running focus session (the Mac's FocusPopoverRow): the phase and the time left, the blocks of the set, a bar
/// through the phase, Skip and Stop. It counts down once a second while it's shown.
class FocusRow extends StatefulWidget {
  const FocusRow({super.key, required this.desktop, required this.status});

  final MochiDesktop desktop;
  final w.FocusStatus status;

  @override
  State<FocusRow> createState() => _FocusRowState();
}

class _FocusRowState extends State<FocusRow> {
  Timer? _second;

  /// The countdown's second (tests): none while the screen can't be seen.
  @visibleForTesting
  bool get ticking => _second != null;

  @override
  void initState() {
    super.initState();
    widget.desktop.rhythm.addListener(_count);
    _count();
  }

  /// Once a second while the screen can be seen; nothing while it can't.
  void _count() {
    if (widget.desktop.rhythm.unseen) {
      _second?.cancel();
      _second = null;
    } else {
      _second ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    widget.desktop.rhythm.removeListener(_count);
    _second?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final status = widget.status;
    final focus = widget.desktop.focus;
    final now = widget.desktop.world.world.date;
    final cycles = focus.cycles;
    final (tint, icon) = switch (status.phase) {
      w.FocusPhase.focus => (p.indigo, status.petNaps ? Icons.bedtime_rounded : Icons.timer_rounded),
      w.FocusPhase.shortBreak => (const Color(0xFF1F9E99), Icons.self_improvement_rounded),
      w.FocusPhase.longBreak => (p.success, Icons.local_cafe_rounded),
    };
    final left = w.focusClock(status.remaining(now));
    final title = '${status.phase.title} $left left';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.s + 2, vertical: Space.s - 1),
      decoration: BoxDecoration(color: tint.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.tile)),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withValues(alpha: 0.14)),
              child: Icon(icon, size: 15, color: tint),
            ),
          ),
          const SizedBox(width: Space.s),
          Expanded(
            child: Semantics(
              label: '$title, focus block ${status.cycle} of $cycles',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.caption.copyWith(
                            color: p.ink,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.xs),
                      Tooltip(
                        message: 'Focus block ${status.cycle} of $cycles',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var index = 1; index <= cycles; index++)
                              Container(
                                width: 6,
                                height: 6,
                                margin: const EdgeInsets.only(left: 3),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: index < status.cycle || (index == status.cycle && status.phase != w.FocusPhase.focus)
                                      ? tint
                                      : tint.withValues(alpha: 0.2),
                                  border: index == status.cycle && status.phase == w.FocusPhase.focus ? Border.all(color: tint) : null,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: status.progress(now),
                      minHeight: 3,
                      color: tint,
                      backgroundColor: tint.withValues(alpha: 0.15),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: Space.xs),
          Tooltip(
            message: status.phase == w.FocusPhase.focus ? 'Start the break now (this block isn’t counted)' : 'End the break and focus again',
            child: TextButton(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: Space.s)),
              onPressed: focus.skip,
              child: const Text('Skip'),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            tooltip: 'Stop focus',
            onPressed: focus.stop,
            icon: const Icon(Icons.stop_rounded),
          ),
        ],
      ),
    );
  }
}

/// The Mac's friendship row: five hearts, the level, and the points to the next one.
class _Friendship extends StatelessWidget {
  const _Friendship({required this.desktop});

  final MochiDesktop desktop;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: desktop.world,
    builder: (context, _) {
      final progress = desktop.world.world.progress;
      final level = progress.friendshipLevel;
      final next = progress.pointsToNextLevel;
      return Semantics(
        container: true,
        label: 'Friendship level $level of ${FriendshipHearts.count}${next == null ? '' : ', $next points to the next'}',
        excludeSemantics: true,
        child: Row(
          children: [
            FriendshipHearts(level: level, size: 11),
            const SizedBox(width: Space.xs),
            Flexible(child: Text('Friendship level $level', overflow: TextOverflow.ellipsis, style: context.type.caption)),
            const Spacer(),
            if (next != null) Text('$next to next', style: context.type.caption.copyWith(color: context.palette.inkSecondary)),
          ],
        ),
      );
    },
  );
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.title,
    required this.label,
    required this.icon,
    required this.tint,
    required this.onTap,
    this.autofocus = false,
    this.selected = false,
  });

  final String title;
  final String label;
  final IconData icon;
  final Color tint;
  final VoidCallback onTap;
  final bool autofocus;

  /// Lit up while it's on (Decorate while decorating), as the Mac's highlighted chip.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClayPress(
      onTap: onTap,
      semanticLabel: label,
      autofocus: autofocus,
      selected: selected,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: Space.s),
        decoration: BoxDecoration(
          color: selected ? p.tint.withValues(alpha: 0.14) : p.sunken,
          borderRadius: BorderRadius.circular(Radii.inner),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: tint),
            const SizedBox(height: 2),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.caption.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// The quick switches, each one a setting (the same ones as in Settings).
class _Switches extends StatelessWidget {
  const _Switches({required this.settings});

  final DesktopSettings settings;

  @override
  Widget build(BuildContext context) {
    final patch = settings.companionName;
    final chips = [
      _SwitchChip(
        title: 'Pause',
        label: 'Pause reactions',
        on: settings.pauseReactions,
        icons: (Icons.pause_circle_filled_rounded, Icons.pause_circle_outline_rounded),
        onChanged: (value) => settings.pauseReactions = value,
      ),
      _SwitchChip(
        title: 'Desktop',
        label: 'Show the desktop pet',
        on: settings.showPet,
        icons: (Icons.pets_rounded, Icons.pets_outlined),
        onChanged: (value) => settings.showPet = value,
      ),
      // On the taskbar (roaming it or playing in its spot, as last chosen), or off it as the classic tray icon.
      _SwitchChip(
        title: 'Taskbar',
        label: 'Mochi on the taskbar',
        on: settings.roamTaskbar,
        icons: (Icons.directions_walk_rounded, Icons.directions_walk_outlined),
        onChanged: settings.showPet ? (value) => settings.roamTaskbar = value : null,
      ),
      _SwitchChip(
        title: patch,
        label: '$patch on the taskbar',
        on: settings.companionOnTaskbar,
        icons: (Icons.laptop_chromebook_rounded, Icons.laptop_outlined),
        onChanged: settings.showPet && settings.roamTaskbar && settings.companionVisibility != CompanionVisibility.never
            ? (value) => settings.companionOnTaskbar = value
            : null,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Four across, or two by two when the text is large.
        final columns = constraints.maxWidth / chips.length < 74 || MediaQuery.textScalerOf(context).scale(1) > 1.4 ? 2 : 4;
        final width = (constraints.maxWidth - Space.s * (columns - 1)) / columns;
        return Wrap(
          spacing: Space.s,
          runSpacing: Space.s,
          children: [for (final chip in chips) SizedBox(width: width, child: chip)],
        );
      },
    );
  }
}

class _SwitchChip extends StatelessWidget {
  const _SwitchChip({required this.title, required this.label, required this.on, required this.icons, required this.onChanged});

  final String title;
  final String label;
  final bool on;
  final (IconData, IconData) icons;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onChanged != null;
    final color = !enabled ? p.inkSecondary.withValues(alpha: 0.5) : (on ? p.tint : p.ink);
    return Tooltip(
      message: label,
      child: MergeSemantics(
        child: Semantics(
          toggled: on,
          child: ClayPress(
            onTap: enabled ? () => onChanged!(!on) : null,
            semanticLabel: label,
            selected: on,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 7),
              decoration: BoxDecoration(
                color: on && enabled ? p.tint.withValues(alpha: 0.14) : p.sunken,
                borderRadius: BorderRadius.circular(Radii.tile),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(on ? icons.$1 : icons.$2, size: 14, color: color),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.caption.copyWith(color: color, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// MARK: - Footer

class _Footer extends StatelessWidget {
  const _Footer({required this.pet, required this.onOpenMain, required this.onAsk, required this.onSettings});

  final String pet;
  final VoidCallback onOpenMain;
  final VoidCallback onAsk;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: Space.s),
      visualDensity: VisualDensity.compact,
    );
    Widget button(String text, IconData icon, VoidCallback onPressed) => TextButton.icon(
      style: style,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    final buttons = [
      button('Open $pet', Icons.open_in_new_rounded, onOpenMain),
      button('Ask $pet', Icons.auto_awesome_rounded, onAsk),
      button('Settings', Icons.settings_rounded, onSettings),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 2),
      // One row, as on the Mac; wrapped when the text is large.
      child: MediaQuery.textScalerOf(context).scale(1) > 1.2
          ? Wrap(alignment: WrapAlignment.spaceBetween, children: buttons)
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [for (final b in buttons) Flexible(child: b)],
            ),
    );
  }
}
