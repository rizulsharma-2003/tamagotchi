import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart' show SeasonalEvent;
import 'package:mochi_link/mochi_link.dart' show LinkStatus;
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/ask_brain.dart' show AskStepState;
import '../../core/ask_mochi.dart';
import '../../core/sessions.dart';
import '../../desktop.dart';
import '../pet/companion_director.dart';
import '../pet/pet_director.dart';
import '../pet/room_view.dart';
import '../widgets/approval_card.dart';
import '../widgets/session_card.dart';

/// The main window, as the phones' home screens: Mochi's name and how Claude is doing, the room with Mochi and Patch,
/// then the sessions and Ask Mochi.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.desktop,
    required this.companion,
    required this.lastActivity,
    required this.onPair,
    required this.onSettings,
    this.askFirst = false,
    this.onInstall,
    this.focusSession,
  });

  final MochiDesktop desktop;

  /// Opened from a Windows notification about this session: its card is scrolled to and outlined.
  final String? focusSession;

  /// Opened from the popover's "Ask Mochi": the question box has the focus.
  final bool askFirst;

  /// Patch (in the room at his desk).
  final CompanionDirector companion;
  final DateTime Function() lastActivity;
  final VoidCallback onPair;
  final VoidCallback onSettings;

  /// "Install Mochi" (null: no offer).
  final VoidCallback? onInstall;

  /// The room's height: the phone's room card, a little shorter for the window.
  static const double roomHeight = 250;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScrollController _scroll = ScrollController();

  MochiDesktop get desktop => widget.desktop;
  CompanionDirector get companion => widget.companion;

  /// The focused session's card.
  final GlobalKey _focusedCard = GlobalKey();

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    if (widget.focusSession != null && widget.focusSession != old.focusSession) _revealFocused();
  }

  /// Scrolls to the focused session's card (down a screen at a time until the list has built it).
  void _revealFocused([int tries = 6]) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final card = _focusedCard.currentContext;
    if (card != null) {
      Scrollable.ensureVisible(card, alignment: 0.3, duration: Duration.zero);
    } else if (tries > 0 && _scroll.hasClients && _scroll.offset < _scroll.position.maxScrollExtent) {
      _scroll.jumpTo((_scroll.offset + _scroll.position.viewportDimension).clamp(0, _scroll.position.maxScrollExtent));
      _revealFocused(tries - 1);
    }
  });

  @override
  void initState() {
    super.initState();
    if (widget.focusSession != null) _revealFocused();
    // Opened for Ask Mochi: down to the question box (the list builds it once it's near), which takes the focus.
    if (widget.askFirst) {
      void down(int times) => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
        if (times > 1) down(times - 1);
      });
      down(3);
      // From a shortcut or the popover the window grows from the pet's size to its own a few frames later: down again
      // once it has.
      for (final wait in const [Duration(milliseconds: 250), Duration(milliseconds: 700)]) {
        _askTimers.add(Timer(wait, () => down(2)));
      }
    }
  }

  final List<Timer> _askTimers = [];

  @override
  void dispose() {
    for (final timer in _askTimers) {
      timer.cancel();
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop.sessions, desktop.hooks, desktop.link, desktop.bridgeProblem, desktop.settings, desktop.installer, companion]),
    builder: (context, _) {
      final sessions = desktop.sessions;
      final live = sessions.all.where((session) => session.isLive || session.phase == SessionPhase.ended).take(8).toList();
      return Scrollbar(
        controller: _scroll,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(Space.l, Space.xs, Space.l, Space.xl),
          children: [
            // First thing on a first run from Downloads: the room is tall, so the offer goes above it.
            if (widget.onInstall != null && InstallCard.offered(desktop)) ...[
              InstallCard(desktop: desktop, onInstall: widget.onInstall!),
              const SizedBox(height: Space.m),
            ],
            _Header(desktop: desktop, companion: companion, lastActivity: widget.lastActivity, onPair: widget.onPair),
            if (desktop.bridgeProblem.value != null) ...[
              const SizedBox(height: Space.m),
              ClayCard(
                child: NoteLabel(text: desktop.bridgeProblem.value!, icon: Icons.warning_amber_rounded, tint: context.palette.warning),
              ),
            ],
            if (!desktop.hooks.connected) ...[const SizedBox(height: Space.m), _ConnectCard(desktop: desktop, onSettings: widget.onSettings)],
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
              for (final session in live) ...[
                SessionCard(
                  key: session.id == widget.focusSession ? _focusedCard : null,
                  session: session,
                  now: sessions.now,
                  highlighted: session.id == widget.focusSession,
                ),
                const SizedBox(height: Space.s),
              ],
            const SizedBox(height: Space.m),
            const SectionTitle(title: 'Ask Mochi'),
            const SizedBox(height: Space.s),
            AskBox(ask: desktop.ask, autofocus: widget.askFirst),
          ],
        ),
      );
    },
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.desktop, required this.companion, required this.lastActivity, required this.onPair});

  final MochiDesktop desktop;
  final CompanionDirector companion;
  final DateTime Function() lastActivity;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final settings = desktop.settings;
    final now = desktop.sessions.now;
    final holiday = settings.holidayOn(now);
    final pet = settings.petName;
    final patch = settings.companionName;
    String greeting(SeasonalEvent event) => switch (event) {
      SeasonalEvent.halloween => 'Happy Halloween',
      SeasonalEvent.diwali => 'Happy Diwali',
      SeasonalEvent.christmas => 'Merry Christmas',
      SeasonalEvent.newYear => 'Happy New Year',
      SeasonalEvent.valentines => "Happy Valentine's Day",
      SeasonalEvent.userBirthday => 'Happy birthday!',
      SeasonalEvent.mochiBirthday => "$pet's birthday",
    };
    final mood = PetMood.of(desktop.sessions, now: now, lastActivity: lastActivity(), rhythm: desktop.rhythm, asleep: desktop.world.asleep);
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
    // "and Patch" while he's around, as the phones say it; otherwise what Mochi is doing.
    final subtitle = companion.visible ? 'and $patch · ${mood.describe(pet)}' : mood.describe(pet);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: Text(pet, style: context.type.largeTitle)),
        const SizedBox(height: 2),
        Text(subtitle, style: context.type.subheadline.copyWith(color: p.inkSecondary)),
        const SizedBox(height: Space.s),
        Wrap(
          spacing: Space.s,
          runSpacing: Space.s,
          children: [
            if (holiday != null) StatusPill(text: greeting(holiday), icon: Icons.celebration_rounded, tint: p.pet),
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
        const SizedBox(height: Space.m),
        Container(
          height: HomeScreen.roomHeight,
          decoration: claySurface(p),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.card),
            child: RoomView(desktop: desktop, companion: companion, lastActivity: lastActivity),
          ),
        ),
        const SizedBox(height: Space.s),
        Text(
          companion.present ? 'Click $pet to pet (hold to purr), or $patch for a wave' : 'Click $pet to pet, hold to purr',
          textAlign: TextAlign.center,
          style: context.type.footnote.copyWith(fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

/// Mochi started from somewhere other than its install folder (Downloads, a build folder): install it, so it can
/// keep itself up to date, or carry on from here with updates off.
class InstallCard extends StatelessWidget {
  const InstallCard({super.key, required this.desktop, required this.onInstall});

  final MochiDesktop desktop;
  final VoidCallback onInstall;

  /// Offered on Windows when this copy isn't the installed one and you haven't said "Not now".
  static bool offered(MochiDesktop desktop) =>
      desktop.installer.supported && !desktop.installer.installed && !desktop.settings.installDeclined;

  @override
  Widget build(BuildContext context) {
    final installer = desktop.installer;
    final p = context.palette;
    return ClayCard(
      outline: p.tint.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: Icons.download_for_offline_outlined, tint: p.tint),
              const SizedBox(width: Space.m),
              Expanded(child: Text('Install Mochi', style: context.type.headline)),
            ],
          ),
          const SizedBox(height: Space.s),
          Text(
            'Mochi is running from ${installer.runningFrom}. Install it for you (no admin rights needed) and it gets a '
            'Start-menu entry and keeps itself up to date. Your settings come along.',
            style: context.type.subheadline,
          ),
          if (installer.problem != null) ...[
            const SizedBox(height: Space.s),
            NoteLabel(text: installer.problem!, icon: Icons.error_outline_rounded, tint: p.danger, textColor: p.danger),
          ],
          const SizedBox(height: Space.m),
          Wrap(
            spacing: Space.s,
            runSpacing: Space.s,
            children: [
              FilledButton(onPressed: installer.busy ? null : onInstall, child: Text(installer.busy ? 'Installing…' : 'Install Mochi')),
              TextButton(
                onPressed: installer.busy ? null : () => desktop.settings.installDeclined = true,
                child: const Text('Not Now'),
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Text('Not now: Mochi runs from here, without updates.', style: context.type.footnote),
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
  const AskBox({super.key, required this.ask, this.autofocus = false});

  final AskMochi ask;

  /// Start with the focus in the question box (and scrolled into view).
  final bool autofocus;

  @override
  State<AskBox> createState() => _AskBoxState();
}

class _AskBoxState extends State<AskBox> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _hadApproval = false;

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
      builder: (context, _) {
        // The card gone (answered, or declined by the time running out): back to the question box.
        final approval = widget.ask.approval;
        if (_hadApproval && approval == null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _focus.requestFocus() : null);
        _hadApproval = approval != null;
        return ClayCard(
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
                      autofocus: widget.autofocus,
                      onSubmitted: (_) => _send(),
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(hintText: 'Ask Mochi, or try “status”', semanticCounterText: ''),
                    ),
                  ),
                  const SizedBox(width: Space.s),
                  IconButton.filled(onPressed: _send, tooltip: 'Send to Mochi', icon: const Icon(Icons.arrow_upward_rounded)),
                ],
              ),
              if (approval != null) ...[
                const SizedBox(height: Space.m),
                ApprovalCard(
                  key: ValueKey(approval.id),
                  approval: approval,
                  pet: widget.ask.petName,
                  onSend: widget.ask.approve,
                  onDecline: widget.ask.decline,
                ),
              ],
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
                            for (final step in exchange.steps.take(4))
                              Text(
                                step.state == AskStepState.failed ? '${step.text} (not done)' : step.text,
                                style: context.type.footnote.copyWith(color: p.inkSecondary),
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
        );
      },
    );
  }
}
