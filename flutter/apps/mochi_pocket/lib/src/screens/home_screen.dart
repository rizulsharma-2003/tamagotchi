import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:mochi_link/mochi_link.dart';

import '../live/live_updates.dart';
import '../model/app_settings.dart';
import '../model/pocket_model.dart';
import '../scene/pose_library.dart';
import '../scene/room_view.dart';
import '../services/alert_notifier.dart';
import '../services/link_opener.dart';
import '../services/platform_bridge.dart';
import '../talk/talk_model.dart';
import '../theme.dart';
import '../voice/updates_reader.dart';
import '../widget/home_widget.dart';
import '../widgets/agent_card.dart';
import '../widgets/cards.dart';
import '../widgets/clay.dart';
import '../widgets/draft_sheet.dart';
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
    this.live,
    this.places,
    this.talk,
    this.homeWidget,
    this.bridge,
  });

  final PocketModel model;
  final PoseLibrary? library;
  final LinkOpener opener;

  /// Alerts as notifications (Settings shows whether they are allowed).
  final AlertNotifier notifier;
  final AppSettings settings;
  final UpdatesReader reader;

  /// Mochi on the lock screen while Claude works (for Settings).
  final LiveUpdates? live;

  /// Where the app is asked to go ([AppPlace]): the widget's taps and the ongoing notification's buttons.
  final Stream<String>? places;

  /// Hold to talk (none: Mochi can only be petted and typed to).
  final TalkModel? talk;

  /// The home-screen widget (for Settings).
  final HomeWidget? homeWidget;

  /// The Quick Settings tile (for Settings).
  final PlatformBridge? bridge;

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
  StreamSubscription<String>? _places;
  StreamSubscription<void>? _cloudTookOver;

  /// Claude's sessions on the computer, where Open the Session brings you.
  final GlobalKey _sessions = GlobalKey();

  PocketModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _announced = model.connection;
    model.addListener(_modelChanged);
    _places = widget.places?.listen(_open);
    // The computer didn't pick up "Check now", so Mochi Cloud did: say so rather than wait for it (the iPhone's
    // `cloudTookOver`).
    _cloudTookOver = model.cloudTookOver.listen(
      (_) => _say(
        '${model.host.yoursCapitalized} is away, so Mochi Cloud is checking — your news arrives as a notification in a minute '
        'or two.',
        seconds: 10,
      ),
    );
  }

  /// Opened to a place: the top (the widget, Open), Claude's sessions (Open the Session when Claude needs you, the
  /// widget's sessions), Updates (the widget's "Waiting for you"), or hands-free (A4): Talk to Mochi (the Quick
  /// Settings tile, a shortcut, Hey Google), What's waiting (read out in Mochi's voice) and Check now. When Hey Google
  /// asked ([AppPlace.voice]), Mochi answers Check now out loud too.
  void _open(String raw) {
    final (place, voice) = AppPlace.parse(raw);
    Navigator.of(context).popUntil((route) => route.isFirst);
    switch (place) {
      case AppPlace.sessions:
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSessions());
      case AppPlace.updates:
        _openUpdates();
      case AppPlace.waiting:
        unawaited(_whatsWaiting());
      case AppPlace.talk:
        _toTop();
        final talk = widget.talk;
        if (talk != null && !talk.isBusy) unawaited(talk.earHeld(byTap: true));
      case AppPlace.check:
        _toTop();
        unawaited(_checkFromOutside(voice: voice));
      default:
        _toTop();
    }
  }

  void _toTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// "What's waiting?" (the iPhone's `WhatsWaitingIntent`): Updates opens and Mochi reads what's waiting, in its own
  /// voice (TalkBack reads it instead when it's on).
  Future<void> _whatsWaiting() async {
    final items = await _waitingNow();
    if (mounted) _openUpdates(readAloud: items);
  }

  /// What's waiting right now (the iPhone's `waitingNow`): the room's card once it has come (a moment after the app
  /// starts), else what the home-screen widget last showed, leaving out what's done and meetings that have started.
  Future<List<AgentNote>> _waitingNow() async {
    await model.until(() => model.agent != null);
    if (model.agent != null) return model.waiting;
    final snapshot = await widget.homeWidget?.read();
    if (snapshot == null || snapshot.room != model.credentials?.room) return const [];
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    return [
      for (final note in snapshot.card?.items ?? const <AgentNote>[])
        if (!model.isDone(note.id) && (note.due == null || note.due! > now - 600)) note,
    ];
  }

  /// Check now from a shortcut or Hey Google: once the room has said whether Mochi Cloud is set up, the same as the
  /// card's button. Asked by voice, Mochi says what it did (the iPhone's `CheckNowIntent`).
  Future<void> _checkFromOutside({required bool voice}) async {
    await model.until(() => model.synced);
    if (!mounted) return;
    final route = await _checkNow();
    if (!voice || !mounted) return;
    final words = switch (route) {
      CheckRoute.cloud || CheckRoute.busy => "Checking now. I'll send you a notification in a minute or two.",
      CheckRoute.computer =>
        model.macOnline ? 'Asking ${model.host.yours} now.' : "${model.host.yoursCapitalized} is away. I'll pass it on when it wakes.",
      CheckRoute.failed => model.cloudError ?? "That didn't go. Try again in a moment.",
    };
    unawaited(widget.reader.say(words, talkBack: MediaQuery.accessibleNavigationOf(context)));
  }

  /// The list builds what's on screen only: until the section is built, jump towards the end, then bring it in.
  void _scrollToSessions([int attempt = 0]) {
    if (!mounted) return;
    final target = _sessions.currentContext;
    if (target != null) {
      unawaited(
        Scrollable.ensureVisible(
          target,
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        ),
      );
      return;
    }
    if (!_scroll.hasClients || attempt >= 6) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSessions(attempt + 1));
  }

  @override
  void dispose() {
    model.removeListener(_modelChanged);
    unawaited(_places?.cancel());
    unawaited(_cloudTookOver?.cancel());
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
      MacConnection.macOnline => '${model.host.yoursCapitalized} is online',
      MacConnection.macAway => '${model.host.yoursCapitalized} is away',
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
    if (!model.macOnline) _say("${model.host.yoursCapitalized} is away. I'll pass it on when it wakes.");
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
    if (model.cloudChecking) return true;
    final latest = model.exchanges.where((exchange) => exchange.text == PocketModel.checkText).lastOrNull;
    return latest != null &&
        (latest.state == ExchangeState.sending || latest.state == ExchangeState.working) &&
        DateTime.now().difference(latest.sentAt) < const Duration(minutes: 2);
  }

  /// "Check now" (the iPhone's `checkForUpdates`): straight to Mochi Cloud when that's on and set up, otherwise the
  /// computer first. Mochi says where it went.
  Future<CheckRoute> _checkNow() async {
    final route = await model.checkNow(useCloud: widget.settings.checkNowUsesCloud);
    if (!mounted) return route;
    switch (route) {
      case CheckRoute.cloud:
        _say('Asking Mochi Cloud… your news arrives as a notification in a minute or two.', seconds: 8);
      case CheckRoute.computer when !model.macOnline && !model.cloudAvailable:
        _say("${model.host.yoursCapitalized} is away. I'll pass it on when it wakes.");
      case CheckRoute.computer || CheckRoute.busy || CheckRoute.failed:
        break;
    }
    return route;
  }

  /// "Draft a reply…" on an email: Mochi Cloud writes it into Gmail Drafts.
  void _draft(AgentNote note) => unawaited(showDraftReply(context, note: note, ask: (words) => model.draftReply(note, words)));

  void _openSettings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(
        model: model,
        notifier: widget.notifier,
        settings: widget.settings,
        reader: widget.reader,
        live: widget.live,
        homeWidget: widget.homeWidget,
        bridge: widget.bridge,
      ),
    ),
  );

  void _openUpdates({List<AgentNote>? readAloud}) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => UpdatesScreen(
        model: model,
        opener: widget.opener,
        reader: widget.reader,
        checkNow: () => unawaited(_checkNow()),
        draft: model.draftsAvailable ? _draft : null,
        readAloud: readAloud,
      ),
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
            listenable: Listenable.merge([model, widget.reader, ?widget.talk]),
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
            text: 'Mochi Link has changed since this version. Update Mochi for Android to keep talking to ${model.host.yours}.',
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
          host: model.host,
          opener: widget.opener,
          markDone: (note) => _markDone(note.id, note.title),
          seeAll: _openUpdates,
          checkNow: () => unawaited(_checkNow()),
          checking: _checking,
          cloudChecking: model.cloudChecking,
          cloudAvailable: model.cloudAvailable,
          cloudSeen: model.cloudSeenAt != null,
          cloudError: model.cloudError,
          draft: model.draftsAvailable ? _draft : null,
          speaking: widget.reader.speaking,
          speak: () =>
              widget.reader.toggle(model.waiting, talkBack: MediaQuery.accessibleNavigationOf(context), time: spokenTimeFor(context)),
        ),
      ],
      gap,
      ..._claude(p),
      if (model.exchanges.isNotEmpty) ...[gap, RecentCard(exchanges: model.exchanges, macOnline: model.macOnline, host: model.host)],
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
                Text(
                  'and ${model.companionName}, from ${model.host.yours}',
                  style: context.type.subheadline.copyWith(color: p.inkSecondary),
                ),
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
              "This phone isn't in ${model.host.name ?? model.host.yours}'s room any more: it was removed on ${model.host.yours}, "
              'or the room was deleted. Pair again to keep talking to ${model.host.yours}.',
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

  Widget _room(MochiPalette p) {
    final talk = widget.talk;
    final holding = talk?.isHolding ?? false;
    // While you talk, Mochi's bubble is what it hears and what it sent; otherwise the Mac's last answer.
    final bubble = talk?.bubble ?? _bubble;
    return Column(
      children: [
        Stack(
          children: [
            Container(
              height: 290,
              decoration: claySurface(p),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.card),
                child: RoomView(model: model, library: widget.library, onPet: () => model.interact('pet'), talk: talk),
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
                  child: bubble == null
                      ? const SizedBox.shrink()
                      // A live region: TalkBack reads what Mochi says (the Mac's reply) as it appears. Not while it
                      // listens: TalkBack reading the words aloud would be heard by the microphone.
                      : Semantics(
                          key: ValueKey(bubble),
                          liveRegion: !holding,
                          label: !holding
                              ? '${model.petName} says: $bubble'
                              : talk!.transcript.isEmpty
                              ? '${model.petName} is listening'
                              : 'Heard: ${talk.transcript}',
                          excludeSemantics: true,
                          child: SpeechBubble(text: bubble, highlighted: holding),
                        ),
                ),
              ),
            ),
            if (talk != null) Positioned(right: Space.s, bottom: Space.s, child: _talkButtons(p, talk)),
          ],
        ),
        const SizedBox(height: Space.s),
        Text(
          _roomHint(talk),
          textAlign: TextAlign.center,
          style: context.type.footnote.copyWith(fontWeight: FontWeight.w500, color: holding ? p.tint : null),
        ),
      ],
    );
  }

  String _roomHint(TalkModel? talk) {
    if (talk == null) return 'Tap ${model.petName} to pet';
    if (talk.cancelArmed) return 'Let go to cancel';
    if (talk.byTap) return 'Listening… tap Send when you’re done';
    if (talk.isHolding) return 'Listening… let go to send, or slide away to cancel';
    return 'Tap ${model.petName} to pet · press and hold to talk';
  }

  /// In the room's corner: Talk (tap to talk, for TalkBack or anyone who'd rather not hold), Send and Cancel while
  /// listening that way, Stop while Mochi is busy with what you said, and Settings when the microphone is blocked.
  Widget _talkButtons(MochiPalette p, TalkModel talk) {
    if (talk.byTap) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RoundIconButton(icon: Icons.close_rounded, label: 'Cancel', tint: p.inkSecondary, onPressed: talk.cancel),
          const SizedBox(width: Space.xs),
          RoundIconButton(icon: Icons.arrow_upward_rounded, label: 'Send', prominent: true, onPressed: () => unawaited(talk.earReleased())),
        ],
      );
    }
    if (talk.microphoneBlocked) {
      return RoundIconButton(
        icon: Icons.settings_rounded,
        label: "Allow the microphone in Mochi's settings",
        onPressed: () => unawaited(talk.openSettings()),
      );
    }
    if (talk.isHolding) return const SizedBox.shrink();
    if (talk.isBusy) return RoundIconButton(icon: Icons.close_rounded, label: 'Stop', tint: p.inkSecondary, onPressed: talk.cancel);
    return RoundIconButton(
      icon: Icons.mic_rounded,
      label: 'Talk to ${model.petName}',
      onPressed: () => unawaited(talk.earHeld(byTap: true)),
    );
  }

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
            decoration: InputDecoration(hintText: 'Tell ${model.petName} what to do on ${model.host.yours}'),
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
        key: _sessions,
        title: 'Claude on ${model.host.yours}',
        note: sessions.isEmpty ? null : '${sessions.length} session${sessions.length == 1 ? '' : 's'}',
      ),
      const SizedBox(height: Space.m),
      if (shared == null)
        note(Icons.chat_bubble_rounded, 'Waiting to hear from ${model.host.yours}…')
      else if (!shared)
        note(
          Icons.chat_bubble_rounded,
          "Turn on “Send Claude's summaries to my phones” in ${model.petName}'s Settings › Phones on ${model.host.yours} to see "
          'what each session did and reply to it here.',
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

/// "Mac online", "PC away since 14:02", "Connecting…": the header's pill.
Widget connectionPill(BuildContext context, PocketModel model) {
  final p = context.palette;
  final host = model.host;
  final lastSeen = model.mac?.lastSeen;
  return switch (model.connection) {
    MacConnection.macOnline => StatusPill(text: host.onlineText, icon: Icons.cloud_done_rounded, tint: p.success),
    MacConnection.macAway => StatusPill(
      text: host.awayText(since: lastSeen == null ? null : clockTime(context, lastSeen)),
      icon: Icons.bedtime_rounded,
      tint: p.inkSecondary,
    ),
    MacConnection.connecting => StatusPill(text: 'Connecting…', icon: Icons.sync_rounded, tint: p.inkSecondary),
    MacConnection.noConnection => StatusPill(text: 'No connection', icon: Icons.cloud_off_rounded, tint: p.warning),
    MacConnection.removed => StatusPill(text: 'Not paired', icon: Icons.link_off_rounded, tint: p.danger),
  };
}
