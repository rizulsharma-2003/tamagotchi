// The Games window (Sprint 2 W14), the Mac's GamesView: Catch the Treats and rock-paper-scissors with Mochi and Patch,
// in Mochi's window. Keys are read only here, while the window has the focus: ← → or A D to run, Space to play or
// pause, Escape to pause; R, P, S or 1, 2, 3 to pick. The mouse drags Mochi along the picnic blanket.
//
// Only the playing field is drawn every frame, and only while a game is being played (the picture repaints from a
// clock; nothing around it is rebuilt). Between games the field's clouds drift at 12 frames a second (still with
// animations off), a round of rock-paper-scissors is drawn smoothly while it plays and gently between rounds, and
// nothing is drawn while the screen can't be seen. The treats pause when the window loses the focus or closes.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:mochi_ui/mochi_ui.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import '../../core/games.dart';
import '../../desktop.dart';
import 'game_art.dart';

class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key, required this.desktop});

  final MochiDesktop desktop;

  /// The keys the games use, as the Mac's window reads them (plain keys only).
  static const String catchHint = '← → or A D to move · drag with the mouse · Space to pause';

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  final FocusNode _focus = FocusNode(debugLabel: 'Games');
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onInactive: _leave, onHide: _leave);

  DesktopGames get games => widget.desktop.games;

  @override
  void initState() {
    super.initState();
    games.show();
    games.addListener(_changed);
    _lifecycle;
  }

  void _leave() => games.leave();

  /// After a pick or a new game the keys keep coming here (a button that was clicked may have gone or be disabled).
  void _changed() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && !_focus.hasFocus) _focus.requestFocus();
  });

  @override
  void dispose() {
    games.removeListener(_changed);
    games.leave();
    _lifecycle.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final pressed = event is KeyDownEvent;
    switch (games.tab) {
      case GameTab.catchTreats:
        final playing = games.catchPhase == CatchPhase.playing;
        if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyA) {
          if (playing) games.session.left = event is! KeyUpEvent;
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyD) {
          if (playing) games.session.right = event is! KeyUpEvent;
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.space) {
          if (pressed) games.toggleCatch();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.escape) {
          // Escape pauses a game; with none going it closes the window as usual.
          final going = playing || games.catchPhase == CatchPhase.paused;
          if (pressed) games.pauseCatch();
          return going ? KeyEventResult.handled : KeyEventResult.ignored;
        }
        return KeyEventResult.ignored;
      case GameTab.rps:
        final choice = w.rpsChoiceForKey(event.character ?? key.keyLabel);
        if (choice == null) return KeyEventResult.ignored;
        if (pressed) games.pick(choice);
        return KeyEventResult.handled;
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _key,
    child: ListenableBuilder(
      listenable: Listenable.merge([games, widget.desktop.settings]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) => Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, Space.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: SegmentedButton<GameTab>(
                    segments: [for (final tab in GameTab.values) ButtonSegment(value: tab, label: Text(tab.title))],
                    selected: {games.tab},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) => games.tab = selection.first,
                  ),
                ),
                const SizedBox(height: Space.m),
                switch (games.tab) {
                  GameTab.catchTreats => _CatchView(desktop: widget.desktop),
                  GameTab.rps => _RPSView(desktop: widget.desktop),
                },
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The look the games draw Mochi and Patch with (the Mac's: the coat and what you chose for them to wear).
GameLook _look(BuildContext context, MochiDesktop desktop) {
  final settings = desktop.settings;
  return GameLook(
    color: settings.petColor,
    petAccessory: settings.petAccessory,
    companionAccessory: settings.companionAccessory,
    reducedMotion: desktop.world.world.reducedMotion || MediaQuery.disableAnimationsOf(context),
    seed: desktop.world.world.seed,
    dark: Theme.of(context).brightness == Brightness.dark,
  );
}

/// A clock for a game's picture: every display frame while [busy], [idleFps] frames a second otherwise (none with
/// animations off), and nothing while the screen can't be seen.
mixin _GameClock<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  MochiDesktop get desktop;
  bool get busy;
  static const double idleFps = 12;

  late final ValueNotifier<double> clock = ValueNotifier(desktop.world.now());
  late final Ticker _ticker = createTicker((_) => onFrame());
  Timer? _idle;
  bool _calm = false;

  /// Frames a second now (tests): 60 for the display's frames, 0 for none.
  double get fps => _ticker.isActive ? 60 : (_idle == null ? 0 : idleFps);

  void onFrame() => clock.value = desktop.world.now();

  void startClock() {
    desktop.rhythm.addListener(syncClock);
    syncClock();
  }

  /// Runs the right clock for what's happening now.
  void syncClock() {
    if (!mounted) return;
    final unseen = desktop.rhythm.unseen;
    if (busy && !unseen) {
      _idle?.cancel();
      _idle = null;
      if (!_ticker.isActive) _ticker.start();
      return;
    }
    if (_ticker.isActive) _ticker.stop();
    if (unseen || _calm) {
      _idle?.cancel();
      _idle = null;
    } else {
      _idle ??= Timer.periodic(Duration(microseconds: (1e6 / idleFps).round()), (_) => onFrame());
    }
    onFrame();
  }

  void calmChanged(BuildContext context) {
    final calm = MediaQuery.disableAnimationsOf(context);
    if (calm == _calm) return;
    _calm = calm;
    WidgetsBinding.instance.addPostFrameCallback((_) => syncClock());
  }

  void stopClock() {
    desktop.rhythm.removeListener(syncClock);
    _idle?.cancel();
    _ticker.dispose();
    clock.dispose();
  }
}

// MARK: - Catch the Treats

class _CatchView extends StatefulWidget {
  const _CatchView({required this.desktop});

  final MochiDesktop desktop;

  @override
  State<_CatchView> createState() => _CatchViewState();
}

class _CatchViewState extends State<_CatchView> with SingleTickerProviderStateMixin, _GameClock {
  @override
  MochiDesktop get desktop => widget.desktop;
  DesktopGames get games => desktop.games;

  @override
  bool get busy => games.catchPhase == CatchPhase.playing;

  CatchPhase _phase = CatchPhase.ready;

  @override
  void initState() {
    super.initState();
    _phase = games.catchPhase;
    games.addListener(_gamesChanged);
    startClock();
  }

  @override
  void onFrame() {
    final now = desktop.world.now();
    games.frame(now);
    clock.value = now;
  }

  void _gamesChanged() {
    final phase = games.catchPhase;
    if (phase != _phase) {
      final was = _phase;
      _phase = phase;
      if (phase == CatchPhase.over && was == CatchPhase.playing) {
        SemanticsService.announce(
          '${games.newRecord ? 'New high score! ' : ''}Game over: ${games.lastScore} points, ${games.lastCaught} caught.',
          TextDirection.ltr,
        );
      }
    }
    syncClock();
  }

  @override
  void dispose() {
    games.removeListener(_gamesChanged);
    stopClock();
    super.dispose();
  }

  void _drag(Offset local, double width) {
    if (games.catchPhase != CatchPhase.playing) return;
    games.session.dragX = CatchFieldPainter.fieldX(local.dx, width);
  }

  @override
  Widget build(BuildContext context) {
    calmChanged(context);
    final settings = desktop.settings;
    final records = settings.games;
    final p = context.palette;
    final pet = settings.petName;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, 560.0);
        final height = width * CatchFieldPainter.design.height / CatchFieldPainter.design.width;
        return Column(
          children: [
            SizedBox(
              width: width,
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ValueListenableBuilder(
                      valueListenable: games.score,
                      builder: (context, score, child) => Semantics(
                        label: 'Catch the Treats. Score $score.',
                        liveRegion: games.catchPhase == CatchPhase.playing,
                        child: child,
                      ),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanDown: (details) => _drag(details.localPosition, width),
                        onPanUpdate: (details) => _drag(details.localPosition, width),
                        onPanEnd: (_) => games.session.dragX = null,
                        onPanCancel: () => games.session.dragX = null,
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: CatchFieldPainter(
                              session: () => games.session,
                              clock: clock,
                              look: _look(context, desktop),
                              best: records.catchHighScore,
                              showHUD: games.catchPhase != CatchPhase.ready,
                            ),
                          ),
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: p.ink.withValues(alpha: 0.08)),
                        ),
                      ),
                    ),
                    if (games.catchPhase != CatchPhase.playing) Center(child: _overlay(context, pet)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.s),
            SizedBox(
              width: width,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: Space.s,
                runSpacing: 2,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.keyboard_outlined, size: 15, color: p.inkSecondary),
                      const SizedBox(width: Space.xs),
                      Flexible(child: Text(GamesScreen.catchHint, style: context.type.caption)),
                    ],
                  ),
                  if (records.catchGamesPlayed > 0)
                    Text(
                      'Best ${records.catchHighScore} · ${records.catchGamesPlayed} ${records.catchGamesPlayed == 1 ? 'game' : 'games'}',
                      style: context.type.caption.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _overlay(BuildContext context, String pet) {
    final p = context.palette;
    switch (games.catchPhase) {
      case CatchPhase.playing:
        return const SizedBox.shrink();
      case CatchPhase.ready:
        return GameCard(
          children: [
            Text('Catch the Treats', textAlign: TextAlign.center, style: context.type.title3.copyWith(fontWeight: FontWeight.w800)),
            Text(
              'Help $pet catch cookies, fish and berries. Golden cookies are a bonus. Three treats on the floor and the picnic '
              'is over.',
              textAlign: TextAlign.center,
              style: context.type.footnote,
            ),
            Tooltip(
              message: 'Space',
              child: FilledButton.icon(onPressed: games.startCatch, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Play')),
            ),
          ],
        );
      case CatchPhase.paused:
        return GameCard(
          children: [
            Text('Paused', style: context.type.title3.copyWith(fontWeight: FontWeight.w800)),
            Text('$pet is waiting patiently.', textAlign: TextAlign.center, style: context.type.footnote),
            Tooltip(
              message: 'Space',
              child: FilledButton.icon(onPressed: games.resumeCatch, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Resume')),
            ),
          ],
        );
      case CatchPhase.over:
        return GameCard(
          children: [
            if (games.newRecord)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.emoji_events_rounded, size: 16, color: p.warning),
                  const SizedBox(width: Space.xs),
                  Text('New high score!', style: context.type.footnote.copyWith(color: p.warning, fontWeight: FontWeight.w800)),
                ],
              ),
            Text(
              '${games.lastScore}',
              style: context.type.largeTitle.copyWith(fontSize: 40, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            Text('${games.lastCaught} caught · best combo ${games.lastBestCombo}', style: context.type.footnote),
            Tooltip(
              message: 'Space',
              child: FilledButton.icon(onPressed: games.startCatch, icon: const Icon(Icons.replay_rounded), label: const Text('Play Again')),
            ),
          ],
        );
    }
  }
}

/// A soft card floating over a game's field (the Mac's GameCard).
class GameCard extends StatelessWidget {
  const GameCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 330),
      child: Container(
        margin: const EdgeInsets.all(Space.m),
        padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.l),
        decoration: BoxDecoration(
          color: p.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 14, offset: const Offset(0, 6))],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (index, child) in children.indexed) ...[if (index > 0) const SizedBox(height: Space.s), child],
            ],
          ),
        ),
      ),
    );
  }
}

// MARK: - Rock, paper, scissors

class _RPSView extends StatefulWidget {
  const _RPSView({required this.desktop});

  final MochiDesktop desktop;

  @override
  State<_RPSView> createState() => _RPSViewState();
}

class _RPSViewState extends State<_RPSView> with SingleTickerProviderStateMixin, _GameClock {
  @override
  MochiDesktop get desktop => widget.desktop;
  DesktopGames get games => desktop.games;

  @override
  bool get busy => games.busy;

  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _revealed = games.revealed;
    games.addListener(_gamesChanged);
    startClock();
  }

  void _gamesChanged() {
    final revealed = games.revealed;
    if (revealed && !_revealed && games.round != null) {
      final settings = desktop.settings;
      final text = games.round!.result(petName: settings.petName, companionName: settings.companionName);
      SemanticsService.announce('${text.headline} ${text.detail}.', TextDirection.ltr);
    }
    _revealed = revealed;
    syncClock();
  }

  @override
  void dispose() {
    games.removeListener(_gamesChanged);
    stopClock();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    calmChanged(context);
    final settings = desktop.settings;
    final pet = settings.petName;
    final patch = settings.companionName;
    final match = games.match;
    final round = games.round;
    final p = context.palette;
    final result = round != null && games.revealed ? round.result(petName: pet, companionName: patch) : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, 560.0);
        final height = width * RPSStagePainter.design.height / RPSStagePainter.design.width;
        final records = settings.games;
        return Column(
          children: [
            Semantics(
              label: result == null ? 'Rock, paper, scissors with $pet.' : '${result.headline} ${result.detail}',
              child: SizedBox(
                width: width,
                height: height,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: RepaintBoundary(
                    child: CustomPaint(painter: RPSStagePainter(games: games, clock: clock, look: _look(context, desktop))),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.m),
            ExcludeSemantics(
              child: result == null
                  ? Text(
                      w.RPSStage.prompt(busy: games.busy, withCompanion: match.withCompanion, petName: pet, companionName: patch),
                      textAlign: TextAlign.center,
                      style: context.type.subheadline.copyWith(color: p.inkSecondary, fontWeight: FontWeight.w600),
                    )
                  : Column(
                      children: [
                        Text(result.headline, textAlign: TextAlign.center, style: context.type.headline.copyWith(fontWeight: FontWeight.w800)),
                        Text(result.detail, textAlign: TextAlign.center, style: context.type.footnote),
                      ],
                    ),
            ),
            const SizedBox(height: Space.m),
            SizedBox(
              width: math.min(width, 420),
              child: Row(
                children: [
                  for (final (index, choice) in w.RPSChoice.values.indexed) ...[
                    if (index > 0) const SizedBox(width: Space.s),
                    Expanded(
                      child: _ChoiceButton(
                        choice: choice,
                        chosen: round?.player == choice && games.busy,
                        onPressed: games.busy ? null : () => games.pick(choice),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Space.m),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: Space.s,
              runSpacing: Space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _TallyChip(title: 'vs $pet', tally: match.vsPet, tint: const Color(0xFFF28A2E)),
                if (match.withCompanion) _TallyChip(title: 'vs $patch', tally: match.vsCompanion, tint: const Color(0xFF26A69A)),
                if (match.streak >= 2)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.local_fire_department_rounded, size: 15, color: Color(0xFFF28A2E)),
                      Text(
                        '${match.streak} in a row',
                        style: context.type.caption.copyWith(color: const Color(0xFFE07A1F), fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: Space.xs),
            Text(
              'All time: ${records.rpsWins} won · ${records.rpsLosses} lost · ${records.rpsDraws} drawn'
              '${records.rpsBestStreak > 1 ? ' · best streak ${records.rpsBestStreak}' : ''}',
              textAlign: TextAlign.center,
              style: context.type.caption.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        );
      },
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({required this.choice, required this.chosen, required this.onPressed});

  final w.RPSChoice choice;
  final bool chosen;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: '${choice.title}, ${choice.keyHint}',
      excludeSemantics: true,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: Space.s, horizontal: Space.xs),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.inner)),
          backgroundColor: chosen ? p.tint.withValues(alpha: 0.16) : p.sunken,
          side: BorderSide(color: chosen ? p.tint : p.stroke),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(choice.emoji, style: const TextStyle(fontSize: 24, fontFamilyFallback: ['Segoe UI Emoji', 'Apple Color Emoji'])),
            Text(
              choice.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.footnote.copyWith(color: p.ink, fontWeight: FontWeight.w700),
            ),
            Text(choice.keyHint, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.caption.copyWith(fontSize: 10.5)),
          ],
        ),
      ),
    );
  }
}

/// Won – lost – drawn against one of them this sitting.
class _TallyChip extends StatelessWidget {
  const _TallyChip({required this.title, required this.tally, required this.tint});

  final String title;
  final w.RPSTally tally;
  final Color tint;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Won – lost – drawn this sitting',
    child: Semantics(
      label: '$title: ${tally.wins} won, ${tally.losses} lost, ${tally.draws} drawn this sitting',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: ShapeDecoration(shape: const StadiumBorder(), color: tint.withValues(alpha: 0.13)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: context.type.caption.copyWith(color: context.palette.ink, fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Text(
              tally.score,
              style: context.type.caption.copyWith(color: tint, fontWeight: FontWeight.w900, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
      ),
    ),
  );
}
