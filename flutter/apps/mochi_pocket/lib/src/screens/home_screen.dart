import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../model/app_settings.dart';
import '../model/pocket_model.dart';
import '../scene/pose_library.dart';
import '../scene/room_view.dart';
import '../services/alert_notifier.dart';
import '../services/link_opener.dart';
import '../theme.dart';
import '../voice/updates_reader.dart';
import '../widgets/agent_card.dart';
import '../widgets/cards.dart';
import '../widgets/clay.dart';
import '../widgets/session_card.dart';
import 'settings_screen.dart';
import 'updates_screen.dart';

/// Mochi's home, mirroring the iPhone's (iOS/MochiPocket/ContentView.swift): the pet's name and the Mac's status,
/// the room, Pet / Play / Treat / Type, the Mac's "Send to Claude?", what's waiting for you, Claude's sessions on the
/// Mac and what you asked lately.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.model,
    required this.library,
    required this.opener,
    required this.notifier,
    required this.settings,
    required this.reader,
  });

  final PocketModel model;
  final PoseLibrary? library;
  final LinkOpener opener;

  /// Alerts as notifications (Settings shows whether they are allowed).
  final AlertNotifier notifier;
  final AppSettings settings;
  final UpdatesReader reader;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _typed = TextEditingController();
  final FocusNode _field = FocusNode();
  final ScrollController _scroll = ScrollController();
  bool _typing = false;

  String? _bubble;
  String? _bubbleFor;
  Timer? _bubbleTimer;
  MacConnection? _announced;

  PocketModel get model => widget.model;

  static const String _checkText = "What's pending?";

  @override
  void initState() {
    super.initState();
    _announced = model.connection;
    model.addListener(_modelChanged);
  }

  @override
  void dispose() {
    model.removeListener(_modelChanged);
    _bubbleTimer?.cancel();
    _typed.dispose();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _modelChanged() {
    _announceConnection();
    // Mochi says the Mac's answer for a few seconds, like on the iPhone.
    final latest = model.exchanges.lastOrNull;
    final reply = latest?.reply;
    if (latest == null || reply == null || latest.state == ExchangeState.sending || latest.state == ExchangeState.working) return;
    final key = '${latest.id}:$reply';
    if (key == _bubbleFor) return;
    _bubbleFor = key;
    _say(reply, seconds: 8);
  }

  /// TalkBack hears when the Mac comes online or goes away (not every reconnect in between).
  void _announceConnection() {
    final now = model.connection;
    if (now == _announced || now == MacConnection.connecting) return;
    _announced = now;
    final text = switch (now) {
      MacConnection.macOnline => 'Your Mac is online',
      MacConnection.macAway => 'Your Mac is away',
      MacConnection.noConnection => 'No connection to Mochi Link',
      MacConnection.removed => "This phone isn't paired any more",
      MacConnection.connecting => '',
    };
    SemanticsService.announce(text, Directionality.of(context));
  }

  void _say(String text, {int seconds = 6}) {
    _bubbleTimer?.cancel();
    setState(() => _bubble = text);
    _bubbleTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) setState(() => _bubble = null);
    });
  }

  void _setTyping(bool typing) {
    setState(() => _typing = typing);
    if (typing) {
      _field.requestFocus();
    } else {
      _field.unfocus();
    }
  }

  void _sendTyped() {
    final sent = model.send(_typed.text);
    if (sent == null) return;
    if (!model.macOnline) _say("Your Mac is away. I'll pass it on when it wakes.");
    _typed.clear();
    _setTyping(false);
    // Back to the room, where Mochi says the Mac's answer.
    if (_scroll.hasClients && _scroll.offset > 0) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
      }
    }
  }

  bool get _checking {
    final latest = model.exchanges.where((exchange) => exchange.text == _checkText).lastOrNull;
    return latest != null &&
        (latest.state == ExchangeState.sending || latest.state == ExchangeState.working) &&
        DateTime.now().difference(latest.sentAt) < const Duration(minutes: 2);
  }

  void _openSettings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(model: model, notifier: widget.notifier, settings: widget.settings, reader: widget.reader),
    ),
  );

  void _openUpdates() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => UpdatesScreen(model: model, opener: widget.opener, reader: widget.reader, checkNow: () => model.send(_checkText)),
    ),
  );

  void _markDone(String id, String title) {
    model.markDone([id]);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Marked “$title” done', maxLines: 2, overflow: TextOverflow.ellipsis),
          action: SnackBarAction(label: 'Undo', onPressed: () => model.markNotDone(id)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // Back closes the typing field first; from the plain home screen it leaves the app.
    canPop: !_typing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _typing) _setTyping(false);
    },
    child: Scaffold(
      body: PocketBackground(
        child: SafeArea(
          bottom: false,
          child: ListenableBuilder(
            listenable: Listenable.merge([model, widget.reader]),
            builder: (context, _) => ListView(
              controller: _scroll,
              // Clear of the gesture bar or navigation buttons at the bottom (edge to edge).
              padding: EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, Space.xl + Space.s + MediaQuery.paddingOf(context).bottom),
              children: _children(context),
            ),
          ),
        ),
      ),
    ),
  );

  List<Widget> _children(BuildContext context) {
    final p = context.palette;
    final approval = model.approval;
    final agent = model.agent;
    const gap = SizedBox(height: Space.l);
    return [
      _header(p),
      if (model.connection == MacConnection.removed) ...[gap, _removed(p)],
      if (model.updateRequired) ...[
        gap,
        ClayCard(
          child: NoteLabel(
            text: 'Mochi Link has changed since this version. Update Mochi for Android to keep talking to your Mac.',
            icon: Icons.system_update_rounded,
            tint: p.warning,
          ),
        ),
      ],
      gap,
      _room(p),
      gap,
      _actions(p),
      if (_typing) ...[gap, _typingField(p)],
      if (approval != null) ...[
        gap,
        ApprovalCard(
          approval: approval,
          answer: (allow) => model.answer(approval, allow: allow),
        ),
      ],
      if (agent != null && agent.enabled) ...[
        gap,
        AgentCard(
          pending: agent,
          waiting: model.waiting,
          petName: model.petName,
          opener: widget.opener,
          markDone: (note) => _markDone(note.id, note.title),
          seeAll: _openUpdates,
          checkNow: () => model.send(_checkText),
          checking: _checking,
          speaking: widget.reader.speaking,
          speak: () =>
              widget.reader.toggle(model.waiting, talkBack: MediaQuery.accessibleNavigationOf(context), time: spokenTimeFor(context)),
        ),
      ],
      gap,
      ..._claude(p),
      if (model.exchanges.isNotEmpty) ...[gap, RecentCard(exchanges: model.exchanges, macOnline: model.macOnline)],
    ];
  }

  // MARK: Header

  Widget _header(MochiPalette p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(header: true, child: Text(model.petName, style: context.type.largeTitle)),
                const SizedBox(height: 2),
                Text('and ${model.companionName}, from your Mac', style: context.type.subheadline.copyWith(color: p.inkSecondary)),
              ],
            ),
          ),
          RoundIconButton(icon: Icons.settings_rounded, label: 'Settings', tint: p.inkSecondary, onPressed: _openSettings),
        ],
      ),
      const SizedBox(height: Space.s),
      Wrap(
        spacing: Space.s,
        runSpacing: Space.s,
        children: [
          connectionPill(context, model),
          if (model.friendshipLevel > 0) StatusPill(text: 'Friendship ${model.friendshipLevel}', icon: Icons.favorite_rounded, tint: p.pet),
        ],
      ),
    ],
  );

  Widget _removed(MochiPalette p) => ClayCard(
    outline: p.danger.withValues(alpha: 0.4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NoteLabel(
          text:
              "This phone isn't in ${model.macName}'s room any more: it was removed on the Mac, or the room was deleted. "
              'Pair again to keep talking to your Mac.',
          icon: Icons.link_off_rounded,
          tint: p.danger,
          textColor: p.ink,
        ),
        const SizedBox(height: Space.m),
        FilledButton(onPressed: model.unpair, child: const Text('Pair Again')),
      ],
    ),
  );

  // MARK: Room

  Widget _room(MochiPalette p) => Column(
    children: [
      Stack(
        children: [
          Container(
            height: 290,
            decoration: claySurface(p),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.card),
              child: RoomView(model: model, library: widget.library, onPet: () => model.interact('pet')),
            ),
          ),
          Positioned(
            left: 22,
            right: 22,
            top: Space.m,
            child: IgnorePointer(
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 250),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(animation), child: child),
                ),
                child: _bubble == null
                    ? const SizedBox.shrink()
                    // A live region: TalkBack reads what Mochi says (the Mac's reply) as it appears.
                    : Semantics(
                        key: ValueKey(_bubble),
                        liveRegion: true,
                        label: '${model.petName} says: $_bubble',
                        excludeSemantics: true,
                        child: SpeechBubble(text: _bubble!),
                      ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: Space.s),
      Text(
        'Tap ${model.petName} to pet',
        textAlign: TextAlign.center,
        style: context.type.footnote.copyWith(fontWeight: FontWeight.w500),
      ),
    ],
  );

  // MARK: Actions

  /// Four across, or two by two when the text is large.
  Widget _actions(MochiPalette p) {
    final large = MediaQuery.textScalerOf(context).scale(1) > 1.4;
    final buttons = [
      ActionButton(title: 'Pet', icon: Icons.favorite_rounded, tint: p.pet, onTap: () => model.interact('pet')),
      ActionButton(title: 'Play', icon: Icons.sports_baseball_rounded, tint: p.play, onTap: () => model.interact('play')),
      ActionButton(title: 'Treat', icon: Icons.cake_rounded, tint: p.warning, onTap: () => model.interact('treat')),
      ActionButton(title: 'Type', icon: Icons.keyboard_rounded, tint: p.tint, selected: _typing, onTap: () => _setTyping(!_typing)),
    ];
    final perRow = large ? 2 : 4;
    return Column(
      children: [
        for (var start = 0; start < buttons.length; start += perRow) ...[
          if (start > 0) const SizedBox(height: Space.s),
          Row(
            children: [
              for (var i = start; i < start + perRow; i++) ...[if (i > start) const SizedBox(width: Space.s), Expanded(child: buttons[i])],
            ],
          ),
        ],
      ],
    );
  }

  Widget _typingField(MochiPalette p) => ClayCard(
    padding: const EdgeInsets.all(Space.m),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _typed,
            focusNode: _field,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendTyped(),
            onChanged: (_) => setState(() {}),
            style: context.type.body,
            decoration: InputDecoration(hintText: 'Tell ${model.petName} what to do on your Mac'),
          ),
        ),
        const SizedBox(width: Space.s),
        IconButton.filled(
          onPressed: _typed.text.trim().isEmpty ? null : _sendTyped,
          tooltip: 'Send',
          icon: const Icon(Icons.arrow_upward_rounded),
        ),
      ],
    ),
  );

  // MARK: Claude on your Mac

  List<Widget> _claude(MochiPalette p) {
    final sessions = model.sessions;
    final shared = model.summariesShared;
    Widget note(IconData icon, String text) => ClayCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(icon: icon, tint: p.inkSecondary),
          const SizedBox(width: Space.m),
          Expanded(child: Text(text, style: context.type.footnote)),
        ],
      ),
    );
    return [
      SectionTitle(
        title: 'Claude on your Mac',
        note: sessions.isEmpty ? null : '${sessions.length} session${sessions.length == 1 ? '' : 's'}',
      ),
      const SizedBox(height: Space.m),
      if (shared == null)
        note(Icons.chat_bubble_rounded, 'Waiting to hear from your Mac…')
      else if (!shared)
        note(
          Icons.chat_bubble_rounded,
          "Turn on “Send Claude's summaries to my iPhone” in ${model.petName}'s Settings › iPhone on your Mac to see what each "
          'session did and reply to it here.',
        )
      else if (sessions.isEmpty)
        note(Icons.bedtime_rounded, 'No Claude sessions right now. When one finishes, its summary shows up here.')
      else
        for (final (index, card) in sessions.indexed) ...[
          if (index > 0) const SizedBox(height: Space.m),
          SessionCard(
            key: ValueKey(card.id),
            card: card,
            send: (text) => model.send(text, project: card.project, session: card.id),
          ),
        ],
    ];
  }
}

/// Times read aloud the way the phone shows them ("4:00 PM" or "16:00"), as the iPhone's short time style.
String Function(DateTime time) spokenTimeFor(BuildContext context) {
  final localizations = MaterialLocalizations.of(context);
  final twentyFour = MediaQuery.alwaysUse24HourFormatOf(context);
  return (time) => localizations.formatTimeOfDay(TimeOfDay.fromDateTime(time), alwaysUse24HourFormat: twentyFour);
}

/// "Mac online", "Mac away since 14:02", "Connecting…": the header's pill.
Widget connectionPill(BuildContext context, PocketModel model) {
  final p = context.palette;
  final lastSeen = model.mac?.lastSeen;
  return switch (model.connection) {
    MacConnection.macOnline => StatusPill(text: 'Mac online', icon: Icons.cloud_done_rounded, tint: p.success),
    MacConnection.macAway => StatusPill(
      text: lastSeen == null ? 'Mac away' : 'Mac away since ${clockTime(context, lastSeen)}',
      icon: Icons.bedtime_rounded,
      tint: p.inkSecondary,
    ),
    MacConnection.connecting => StatusPill(text: 'Connecting…', icon: Icons.sync_rounded, tint: p.inkSecondary),
    MacConnection.noConnection => StatusPill(text: 'No connection', icon: Icons.cloud_off_rounded, tint: p.warning),
    MacConnection.removed => StatusPill(text: 'Not paired', icon: Icons.link_off_rounded, tint: p.danger),
  };
}
