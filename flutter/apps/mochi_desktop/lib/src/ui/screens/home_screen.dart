import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:mochi_art/mochi_art.dart' show SeasonalEvent;
import 'package:mochi_link/mochi_link.dart' show LinkStatus;
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/ask_attach.dart';
import '../../core/ask_brain.dart' show AskStepState;
import '../../core/ask_mochi.dart';
import '../../core/screen_peek.dart' show ScreenPeek;
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

  /// Bumped each time Ask Mochi is asked for while this screen already shows: the question box takes the focus again.
  final ValueNotifier<int> _focusAsk = ValueNotifier(0);

  MochiDesktop get desktop => widget.desktop;
  CompanionDirector get companion => widget.companion;

  /// The focused session's card.
  final GlobalKey _focusedCard = GlobalKey();

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    if (widget.focusSession != null && widget.focusSession != old.focusSession) _revealFocused();
    // Ask Mochi from the tray, a shortcut or the jump list while the window already shows: down to the box, with the focus.
    if (widget.askFirst && !old.askFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        _focusAsk.value++;
      });
    }
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
    _focusAsk.dispose();
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
            AskBox(ask: desktop.ask, autofocus: widget.askFirst, focusSignal: _focusAsk),
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

/// Type a question for Mochi; answers (and what the phones asked) below, newest first. What you hand Mochi shows here first,
/// to edit or remove, and nothing is sent before Send: "Ask about what I copied" (X15) reads the clipboard's text when
/// pressed (never otherwise); files, text and links dropped on Mochi arrive as chips and a text box (X13, X14); and
/// "What's on my screen?" (X17, only while Settings has it on) shows a picture of one window on a preview card.
class AskBox extends StatefulWidget {
  const AskBox({super.key, required this.ask, this.autofocus = false, this.focusSignal, this.clipboard = const SystemClipboardText()});

  final AskMochi ask;

  /// Start with the focus in the question box (and scrolled into view).
  final bool autofocus;

  /// Each change gives the question box the focus (Ask Mochi asked for again while the window shows).
  final Listenable? focusSignal;

  /// Where "Ask about what I copied" reads from.
  final ClipboardText clipboard;

  @override
  State<AskBox> createState() => _AskBoxState();
}

/// Whose words the text attachment holds.
enum _TextKind { copied, dropped }

class _AskBoxState extends State<AskBox> {
  final TextEditingController _text = TextEditingController();
  final TextEditingController _copied = TextEditingController();
  final FocusNode _focus = FocusNode();
  final FocusNode _copiedFocus = FocusNode(debugLabel: 'Copied text');
  bool _hadApproval = false;

  /// A text is attached (copied from the clipboard, or dropped): it can be edited or removed.
  bool _attached = false;
  _TextKind _kind = _TextKind.copied;
  bool _cut = false;
  bool _reading = false;

  /// Mochi's words when the clipboard had nothing to read.
  String? _clipboardNote;

  /// How many files and links the draft had when it last changed (more of them: the question box takes the focus).
  int _draftCount = 0;

  AskDraft get _draft => widget.ask.draft;
  ScreenPeek? get _peek => widget.ask.peek;

  @override
  void initState() {
    super.initState();
    widget.focusSignal?.addListener(_takeFocus);
    _draft.addListener(_draftChanged);
    _peek?.addListener(_peekChanged);
    // Dropped on Mochi's pet window: Ask Mochi opened with it already waiting.
    final waiting = _draft.takeText();
    if (waiting != null) _adopt(waiting);
    _draftCount = _draft.files.length + _draft.links.length;
  }

  void _adopt(({String text, bool cut}) dropped) {
    _attached = true;
    _kind = _TextKind.dropped;
    _cut = dropped.cut;
    _clipboardNote = null;
    _copied.text = dropped.text;
  }

  @override
  void didUpdateWidget(AskBox old) {
    super.didUpdateWidget(old);
    if (old.focusSignal != widget.focusSignal) {
      old.focusSignal?.removeListener(_takeFocus);
      widget.focusSignal?.addListener(_takeFocus);
    }
    if (old.ask != widget.ask) {
      old.ask.draft.removeListener(_draftChanged);
      old.ask.peek?.removeListener(_peekChanged);
      _draft.addListener(_draftChanged);
      _peek?.addListener(_peekChanged);
    }
  }

  void _takeFocus() {
    if (mounted) _focus.requestFocus();
  }

  void _draftChanged() {
    if (!mounted) return;
    final dropped = _draft.takeText();
    final count = _draft.files.length + _draft.links.length;
    final more = dropped != null || count > _draftCount;
    _draftCount = count;
    setState(() {
      if (dropped != null) _adopt(dropped);
    });
    // On to the question about it.
    if (more) _focus.requestFocus();
  }

  void _peekChanged() {
    if (mounted) setState(() {});
  }

  /// What the text attachment is called: "copied" or "dropped".
  String get _word => _kind == _TextKind.copied ? 'copied' : 'dropped';

  void _send() {
    final text = _text.text.trim();
    final attachedText = _attached ? _copied.text : null;
    final copied = _kind == _TextKind.copied ? attachedText : null;
    final dropped = _kind == _TextKind.dropped ? attachedText : null;
    final peek = _peek;
    final extras = AskExtras(dropped: dropped, files: _draft.files, links: _draft.links, screen: peek?.preview);
    if (text.isEmpty && (copied == null || copied.trim().isEmpty) && extras.isEmpty) return;
    _text.clear();
    _removeCopied(refocus: false);
    _draft.clear();
    peek?.remove();
    widget.ask.ask(text, copied: copied, extras: extras.isEmpty ? null : extras);
    _focus.requestFocus();
  }

  /// Reads the clipboard (only here, when the button is pressed): text only, at most [AskCopied.maxCharacters].
  Future<void> _readClipboard() async {
    if (_reading) return;
    setState(() {
      _reading = true;
      _clipboardNote = null;
    });
    String? copied;
    try {
      copied = await widget.clipboard.read();
    } on Object {
      copied = null;
    }
    if (!mounted) return;
    if (copied == null || copied.trim().isEmpty) {
      setState(() {
        _reading = false;
        _clipboardNote =
            "${widget.ask.petName} looks, but there's no text on your clipboard (it's empty, or it holds a picture or files). "
            'Copy some text, then press the button again.';
      });
      return;
    }
    final limited = AskCopied.limit(copied);
    setState(() {
      _reading = false;
      _attached = true;
      _kind = _TextKind.copied;
      _cut = limited.cut;
      _copied.text = limited.text;
    });
    // On to the question about it.
    _focus.requestFocus();
  }

  void _removeCopied({bool refocus = true}) {
    if (!_attached && !refocus) return;
    setState(() {
      _attached = false;
      _cut = false;
      _clipboardNote = null;
      _copied.clear();
    });
    if (refocus) _focus.requestFocus();
  }

  @override
  void dispose() {
    widget.focusSignal?.removeListener(_takeFocus);
    _draft.removeListener(_draftChanged);
    _peek?.removeListener(_peekChanged);
    _text.dispose();
    _copied.dispose();
    _focus.dispose();
    _copiedFocus.dispose();
    super.dispose();
  }

  Widget _copiedCard(BuildContext context, String pet) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: _copied,
      builder: (context, _) {
        final count = _copied.text.length;
        return Container(
          padding: const EdgeInsets.all(Space.s),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: p.tint.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_kind == _TextKind.copied ? Icons.content_paste_rounded : Icons.text_snippet_outlined, size: 16, color: p.tint),
                  const SizedBox(width: Space.xs),
                  Expanded(
                    child: Text(
                      'What you $_word · $count character${count == 1 ? '' : 's'}',
                      style: context.type.footnote.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(onPressed: _removeCopied, tooltip: 'Remove what I $_word', icon: const Icon(Icons.close_rounded, size: 18)),
                ],
              ),
              Semantics(
                label: 'The text you $_word. You can edit it before sending.',
                child: TextField(
                  controller: _copied,
                  focusNode: _copiedFocus,
                  minLines: 2,
                  maxLines: 6,
                  inputFormatters: [LengthLimitingTextInputFormatter(AskCopied.maxCharacters)],
                  style: context.type.footnote,
                  decoration: const InputDecoration(isDense: true, semanticCounterText: ''),
                ),
              ),
              const SizedBox(height: Space.xs),
              if (_cut)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'It was longer, so only the first ${AskCopied.maxCharacters} characters are here.',
                    style: context.type.footnote.copyWith(color: p.warning),
                  ),
                ),
              Text(
                'Nothing leaves this PC until you press Send. $pet sees this with your question, and it is not saved.',
                style: context.type.footnote.copyWith(color: p.inkSecondary),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The files and links handed over, as chips with a remove button each.
  Widget _chips(BuildContext context) {
    final p = context.palette;
    Widget chip({required IconData icon, required String label, required String semantics, required String remove, required VoidCallback onRemove}) {
      // The chip reads as its label (the file's name and size, or the link); its x button is named by the tooltip.
      return InputChip(
        avatar: Icon(icon, size: 16, color: p.tint),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.footnote),
        ),
        tooltip: semantics,
        onDeleted: onRemove,
        deleteButtonTooltipMessage: remove,
        visualDensity: VisualDensity.compact,
      );
    }

    return Wrap(
      spacing: Space.xs,
      runSpacing: Space.xs,
      children: [
        for (final file in _draft.files)
          chip(
            icon: Icons.insert_drive_file_outlined,
            label: '${file.name} · ${file.sizeText}',
            semantics: 'File ${file.name}, ${file.sizeText}',
            remove: 'Remove ${file.name}',
            onRemove: () {
              _draft.removeFile(file);
              _focus.requestFocus();
            },
          ),
        for (final link in _draft.links)
          chip(
            icon: Icons.link_rounded,
            label: link.toString(),
            semantics: 'Link ${link.host}',
            remove: 'Remove the link to ${link.host}',
            onRemove: () {
              _draft.removeLink(link);
              _focus.requestFocus();
            },
          ),
      ],
    );
  }

  /// The picture of the window, before anything is sent.
  Widget _screenCard(BuildContext context, ScreenPreview preview, String pet) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(Space.s),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.tint.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.window_rounded, size: 16, color: p.tint),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text('Your ${preview.app} window', style: context.type.footnote.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Image.memory(
                preview.png,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                semanticLabel: 'A picture of your ${preview.app} window, taken just now',
                errorBuilder: (context, error, stack) => Text('(The picture can’t be shown here, but it is ready.)', style: context.type.footnote),
              ),
            ),
          ),
          const SizedBox(height: Space.xs),
          Text(
            'This is exactly what $pet would see. Nothing leaves this PC until you press Send, and the picture is deleted when the question is done.',
            style: context.type.footnote.copyWith(color: p.inkSecondary),
          ),
          const SizedBox(height: Space.xs),
          Row(
            children: [
              TextButton(onPressed: () => _peek?.remove(), child: const Text('Remove')),
              const SizedBox(width: Space.xs),
              FilledButton(onPressed: _send, child: const Text('Send')),
            ],
          ),
        ],
      ),
    );
  }

  /// The suggestion in the question box.
  String _hint() {
    final peek = _peek;
    if (peek?.preview != null) return "What's on my screen?";
    if (_draft.files.isNotEmpty) return _draft.files.length == 1 ? "What's in this file?" : "What's in these files?";
    if (_draft.links.isNotEmpty) return "What's this link about?";
    if (_attached) return 'Ask about what you $_word';
    return 'Ask Mochi, or try “status”';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.ask, _draft]),
      builder: (context, _) {
        // The card gone (answered, or declined by the time running out): back to the question box.
        final approval = widget.ask.approval;
        if (_hadApproval && approval == null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _focus.requestFocus() : null);
        _hadApproval = approval != null;
        final peek = _peek;
        final preview = peek?.preview;
        final dropNote = _draft.note;
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.card),
            border: _draft.hovering ? Border.all(color: p.tint, width: 2) : null,
          ),
          child: ClayCard(
            padding: const EdgeInsets.all(Space.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_draft.hovering)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        'Drop it here and ${widget.ask.petName} will look. Nothing is sent until you press Send.',
                        style: context.type.footnote.copyWith(color: p.tint, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        focusNode: _focus,
                        autofocus: widget.autofocus,
                        onSubmitted: (_) => _send(),
                        textInputAction: TextInputAction.send,
                        decoration: InputDecoration(hintText: _hint(), semanticCounterText: ''),
                      ),
                    ),
                    const SizedBox(width: Space.s),
                    IconButton.filled(onPressed: _send, tooltip: 'Send to Mochi', icon: const Icon(Icons.arrow_upward_rounded)),
                  ],
                ),
                const SizedBox(height: Space.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: Space.xs,
                    children: [
                      Semantics(
                        button: true,
                        label:
                            'Ask about what I copied: reads the text on your clipboard now and adds it to your question. '
                            'Nothing is sent until you press Send.',
                        excludeSemantics: true,
                        onTap: _reading ? null : _readClipboard,
                        child: TextButton.icon(
                          onPressed: _reading ? null : _readClipboard,
                          icon: const Icon(Icons.content_paste_rounded, size: 18),
                          label: const Text('Ask about what I copied'),
                        ),
                      ),
                      if (peek != null && peek.enabled)
                        Semantics(
                          button: true,
                          label:
                              "What's on my screen?: takes one picture of the window you were using before Mochi came up and "
                              'shows it here. Nothing is sent until you press Send.',
                          excludeSemantics: true,
                          onTap: peek.busy ? null : peek.look,
                          child: TextButton.icon(
                            onPressed: peek.busy ? null : peek.look,
                            icon: const Icon(Icons.desktop_windows_outlined, size: 18),
                            label: const Text("What's on my screen?"),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_clipboardNote != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: Semantics(
                      liveRegion: true,
                      child: NoteLabel(text: _clipboardNote!, icon: Icons.info_outline_rounded, tint: p.warning),
                    ),
                  ),
                if (dropNote != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: Semantics(
                      liveRegion: true,
                      child: NoteLabel(text: dropNote, icon: Icons.info_outline_rounded, tint: p.warning),
                    ),
                  ),
                if (peek?.note != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: Semantics(
                      liveRegion: true,
                      child: NoteLabel(text: peek!.note!, icon: Icons.info_outline_rounded, tint: p.warning),
                    ),
                  ),
                if (_draft.files.isNotEmpty || _draft.links.isNotEmpty) ...[
                  const SizedBox(height: Space.xs),
                  _chips(context),
                  const SizedBox(height: Space.xs),
                  Text(
                    'Nothing leaves this PC until you press Send. Claude Code reads only the files you dropped, for this question.',
                    style: context.type.footnote.copyWith(color: p.inkSecondary),
                  ),
                ],
                if (_attached) ...[const SizedBox(height: Space.xs), _copiedCard(context, widget.ask.petName)],
                if (preview != null) ...[const SizedBox(height: Space.xs), _screenCard(context, preview, widget.ask.petName)],
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
                                [
                                  exchange.text,
                                  if (exchange.copiedCharacters > 0) 'with what you copied',
                                  if (exchange.droppedCharacters > 0) 'with what you dropped',
                                  if (exchange.files > 0) 'with ${exchange.files} file${exchange.files == 1 ? '' : 's'}',
                                  if (exchange.links > 0) 'with ${exchange.links == 1 ? 'a link' : '${exchange.links} links'}',
                                  if (exchange.screen) 'with a picture of your window',
                                  if (exchange.fromPhone) 'from your phone',
                                ].join('  ·  '),
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
          ),
        );
      },
    );
  }
}
