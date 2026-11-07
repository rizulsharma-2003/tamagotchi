import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart' show SeasonalEvent;
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_link/mochi_link.dart' show LinkStatus;
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/ask_mochi.dart';
import '../../core/sessions.dart';
import '../../desktop.dart';
import '../pet/mochi_view.dart';
import '../pet/pet_director.dart';
import '../widgets/session_card.dart';

/// The main window: Mochi and how Claude is doing, the sessions, Ask Mochi.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.desktop,
    required this.library,
    required this.lastActivity,
    required this.onPair,
    required this.onSettings,
  });

  final MochiDesktop desktop;
  final PoseLibrary? library;
  final DateTime Function() lastActivity;
  final VoidCallback onPair;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop.sessions, desktop.hooks, desktop.link, desktop.bridgeProblem, desktop.settings]),
    builder: (context, _) {
      final sessions = desktop.sessions;
      final live = sessions.all.where((session) => session.isLive || session.phase == SessionPhase.ended).take(8).toList();
      return Scrollbar(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.l, Space.xs, Space.l, Space.xl),
          children: [
            _Header(desktop: desktop, library: library, lastActivity: lastActivity, onPair: onPair),
            if (desktop.bridgeProblem.value != null) ...[
              const SizedBox(height: Space.m),
              ClayCard(
                child: NoteLabel(text: desktop.bridgeProblem.value!, icon: Icons.warning_amber_rounded, tint: context.palette.warning),
              ),
            ],
            if (!desktop.hooks.connected) ...[const SizedBox(height: Space.m), _ConnectCard(desktop: desktop, onSettings: onSettings)],
            const SizedBox(height: Space.m),
            SectionTitle(title: 'Claude sessions', note: live.isEmpty ? null : '${sessions.live.length} open'),
            const SizedBox(height: Space.s),
            if (live.isEmpty)
              ClayCard(
                child: NoteLabel(
                  icon: Icons.terminal_rounded,
                  text: desktop.hooks.connected
                      ? 'No Claude sessions yet. Start Claude Code in a terminal or your editor and Mochi follows along.'
                      : 'Connect Claude Code first, then start a session.',
                ),
              )
            else
              for (final session in live) ...[SessionCard(session: session, now: sessions.now), const SizedBox(height: Space.s)],
            const SizedBox(height: Space.m),
            const SectionTitle(title: 'Ask Mochi'),
            const SizedBox(height: Space.s),
            AskBox(ask: desktop.ask),
          ],
        ),
      );
    },
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.desktop, required this.library, required this.lastActivity, required this.onPair});

  final MochiDesktop desktop;
  final PoseLibrary? library;
  final DateTime Function() lastActivity;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final settings = desktop.settings;
    final now = desktop.sessions.now;
    final holiday = settings.holidayOn(now);
    String greeting(SeasonalEvent event) => switch (event) {
      SeasonalEvent.halloween => 'Happy Halloween',
      SeasonalEvent.diwali => 'Happy Diwali',
      SeasonalEvent.christmas => 'Merry Christmas',
      SeasonalEvent.newYear => 'Happy New Year',
      SeasonalEvent.valentines => "Happy Valentine's Day",
      SeasonalEvent.userBirthday => 'Happy birthday!',
      SeasonalEvent.mochiBirthday => "${settings.petName}'s birthday",
    };
    final mood = PetMood.of(desktop.sessions, now: now, lastActivity: lastActivity());
    final link = desktop.link;
    final phones = link.devices.where((peer) => peer.role == 'pocket').toList();
    final online = phones.where((peer) => peer.online).length;
    final (linkText, linkTint) = !link.paired
        ? ('No phone paired', p.inkSecondary)
        : switch (link.status) {
            LinkStatus.online => (
              phones.isEmpty ? 'Waiting for a phone' : '$online of ${phones.length} phone${phones.length == 1 ? '' : 's'} online',
              online > 0 ? p.success : p.inkSecondary,
            ),
            LinkStatus.connecting => ('Connecting…', p.inkSecondary),
            LinkStatus.offline => ('Mochi Link offline', p.warning),
            LinkStatus.removed => ('Pairing removed', p.danger),
          };
    final primary = desktop.sessions.primary;
    final claudeText = switch (mood) {
      PetMood.needsYou => 'Claude needs you${primary?.project == null ? '' : ' in ${primary!.project}'}',
      PetMood.watching => 'Claude is working${primary?.project == null ? '' : ' on ${primary!.project}'}',
      PetMood.happy => 'Claude finished',
      PetMood.concerned => 'Claude hit a snag',
      _ => desktop.sessions.live.isEmpty ? 'No Claude sessions' : 'Claude is idle',
    };
    return ClayCard(
      padding: const EdgeInsets.all(Space.m),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            height: 92,
            child: MochiView(
              sessions: desktop.sessions,
              cues: desktop.cues,
              library: library,
              lastActivity: lastActivity,
              color: settings.petColor,
              accessory: settings.wornByPet(now),
            ),
          ),
          const SizedBox(width: Space.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(settings.petName, style: context.type.title3),
                Text(mood.describe(settings.petName), style: context.type.footnote),
                const SizedBox(height: Space.s),
                Wrap(
                  spacing: Space.s,
                  runSpacing: Space.s,
                  children: [
                    if (holiday != null)
                      StatusPill(text: greeting(holiday), icon: Icons.celebration_rounded, tint: p.pet),
                    StatusPill(text: claudeText, icon: Icons.auto_awesome_rounded, tint: mood == PetMood.needsYou ? p.warning : p.indigo),
                    Semantics(
                      button: true,
                      label: '$linkText. Pair a phone',
                      excludeSemantics: true,
                      child: ClayPress(
                        onTap: onPair,
                        borderRadius: BorderRadius.circular(40),
                        child: StatusPill(text: linkText, icon: Icons.smartphone_rounded, tint: linkTint),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  const _ConnectCard({required this.desktop, required this.onSettings});

  final MochiDesktop desktop;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final hooks = desktop.hooks;
    final p = context.palette;
    return ClayCard(
      outline: p.tint.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: Icons.link_rounded, tint: p.tint),
              const SizedBox(width: Space.m),
              Expanded(
                child: Text(hooks.needsUpdate ? 'Update the Claude Code connection' : 'Connect Claude Code', style: context.type.headline),
              ),
            ],
          ),
          const SizedBox(height: Space.s),
          Text(
            'Mochi follows your Claude Code sessions through hooks in your Claude Code settings. Only what Claude is doing '
            '(the kind of tool, when it needs you) reaches Mochi: never your prompts or code.',
            style: context.type.subheadline,
          ),
          if (hooks.problem != null) ...[
            const SizedBox(height: Space.s),
            NoteLabel(text: hooks.problem!, icon: Icons.error_outline_rounded, tint: p.danger, textColor: p.danger),
          ],
          const SizedBox(height: Space.m),
          Wrap(
            spacing: Space.s,
            runSpacing: Space.s,
            children: [
              FilledButton(onPressed: hooks.busy ? null : hooks.connect, child: Text(hooks.needsUpdate ? 'Update' : 'Connect Claude Code')),
              TextButton(onPressed: onSettings, child: const Text('More in Settings')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Type a question for Mochi; answers (and what the phones asked) below, newest first.
class AskBox extends StatefulWidget {
  const AskBox({super.key, required this.ask});

  final AskMochi ask;

  @override
  State<AskBox> createState() => _AskBoxState();
}

class _AskBoxState extends State<AskBox> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  void _send() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    widget.ask.ask(text);
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: widget.ask,
      builder: (context, _) => ClayCard(
        padding: const EdgeInsets.all(Space.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    onSubmitted: (_) => _send(),
                    textInputAction: TextInputAction.send,
                    decoration: const InputDecoration(hintText: 'Ask Mochi, or try “status”', semanticCounterText: ''),
                  ),
                ),
                const SizedBox(width: Space.s),
                IconButton.filled(onPressed: _send, tooltip: 'Send to Mochi', icon: const Icon(Icons.arrow_upward_rounded)),
              ],
            ),
            for (final exchange in widget.ask.exchanges.reversed.take(4)) ...[
              const SizedBox(height: Space.m),
              MergeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: switch (exchange.state) {
                        AskState.working => SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: 'Mochi is thinking', color: p.tint),
                        ),
                        AskState.done => Icon(Icons.chat_bubble_rounded, size: 16, color: p.success, semanticLabel: 'Answered'),
                        AskState.failed => Icon(Icons.info_rounded, size: 16, color: p.warning, semanticLabel: 'Not done'),
                      },
                    ),
                    const SizedBox(width: Space.s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            exchange.fromPhone ? '${exchange.text}  ·  from your phone' : exchange.text,
                            style: context.type.footnote.copyWith(fontWeight: FontWeight.w700, color: p.ink),
                          ),
                          if (exchange.reply != null) Text(exchange.reply!, style: context.type.subheadline),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
