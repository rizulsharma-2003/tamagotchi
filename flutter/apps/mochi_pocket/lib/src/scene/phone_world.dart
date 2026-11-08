// Mochi's world on the phone (Sprint 2 A5, docs/MOCHI_WORLD.md "Android"): one `MochiWorld` (mochi_world, the Mac's
// CompanionWorld in Dart) for the room, as the iPhone runs one CompanionWorld (iOS/MochiPocket/PhoneWorld.swift). It
// decides what Mochi and Patch do: their loops, the moments they share (a coffee, a game, a high five), petting, play
// and treats, naps, Patch reacting to Claude's tools.
//
// It follows the computer through Mochi Link, exactly as the iPhone does:
// - The look: the names here; the colours, room, things to wear and the holidays are drawn by the room (room_view.dart).
// - What Claude is doing there (`claude`: phase, tool category, resting) becomes *simulated* hook events for a mirror
//   session, so Patch works the way Claude works and Mochi watches, waves when Claude needs you and celebrates when it
//   finishes. Simulated events animate but never count: the computer keeps the real friendship and achievements, and the
//   header shows its level (the look's). Nothing the phone counts is kept or shown.
// - The computer resting: Mochi naps here too, and wakes with a stretch when it's in use again.
// - Petting, play and treats both ways: the phone's own (sent to the computer by PocketModel) and the computer's.
//
// Small differences from the iPhone, all deliberate:
// - The first state seen after launch or pairing sets the scene quietly: Patch is already typing, but there's no high
//   five for a turn that ended before you looked.
// - A mirrored tool still "running" when the next state comes finishes first, so the events stay in order (on the
//   iPhone its PostToolUse can land after "Claude needs you" and stop Mochi waving).
// - Mochi's own birthday isn't decorated: the look doesn't carry the day the computer adopted Mochi.
// - Android's "Remove animations" gives the Mac's Reduce Motion poses (the iPhone's room doesn't follow Reduce Motion).
//
// It ticks four times a second (as the Mac and the iPhone do) only while the room can be seen: the app in front and the
// room on screen (RoomView says when). Nothing ticks in the background. Nothing is written to disk: like the iPhone's
// world, a new launch starts calm with a new seed, and the look and Claude's state come back from the room.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mochi_world/mochi_world.dart';

import '../model/pocket_model.dart';

/// What Claude is doing on the computer, as far as the mirror session goes (Swift `ClaudeMirror` without `at`).
@immutable
class _Mirror {
  const _Mirror(this.phase, [this.category, this.resting = false]);

  final String phase;
  final String? category;
  final bool resting;

  @override
  bool operator ==(Object other) => other is _Mirror && other.phase == phase && other.category == category && other.resting == resting;

  @override
  int get hashCode => Object.hash(phase, category, resting);
}

class PhoneWorld extends ChangeNotifier {
  PhoneWorld({
    required this.model,
    int? seed,
    DateTime Function()? clock,
    double Function()? uptime,
    WorldCalendar calendar = const WorldCalendar.local(),
    this.tickInterval = const Duration(milliseconds: 250),
    this.toolDelay = const Duration(milliseconds: 1600),
  }) : _clock = clock ?? DateTime.now,
       _calendar = calendar {
    world = MochiWorld(
      // On the phone Patch keeps Mochi company at the desk all the time (the iPhone's `companionVisibility = .always`).
      settings: const WorldSettings(companionVisibility: CompanionVisibility.always),
      seed: seed,
      clock: _clock,
      uptime: uptime,
      calendar: calendar,
    );
    model.addListener(_follow);
    _cues = model.cues.listen(_cue);
    _follow();
  }

  final PocketModel model;

  /// How often the world moves on while the room can be seen (the Mac's and the iPhone's 4 Hz).
  final Duration tickInterval;

  /// How long a mirrored tool "runs" before its PostToolUse (the iPhone's 1.6 s). A new state from the computer before
  /// then finishes it first, so the events stay in order (Claude waiting for you stays waiting).
  final Duration toolDelay;

  final DateTime Function() _clock;
  final WorldCalendar _calendar;
  late final MochiWorld world;
  late final StreamSubscription<PetCue> _cues;
  final math.Random _random = math.Random();

  Timer? _ticker;

  /// The mirrored tool still "running", and how it finishes.
  ({Timer timer, void Function() finish})? _tool;
  bool _roomVisible = false;
  bool _disposed = false;

  _Mirror _mirror = const _Mirror('none');
  String? _mirrorSession;
  bool _inTurn = false;
  int _eventCount = 0;

  /// The next state from the computer only sets the scene (at launch, or after pairing): no reaction to it.
  bool _quiet = true;

  SeasonalEvent? _season;
  (int, SeasonalSettings)? _seasonKey;
  Object? _signature;
  final ValueNotifier<String?> _saying = ValueNotifier(null);

  /// The world's clock (seconds, monotonic): what the room draws by.
  double get now => world.now;

  /// The world is ticking (only while the room can be seen).
  bool get ticking => _ticker != null;

  /// Today's holiday decorations and costumes, from the computer's look (none when it turned them off).
  SeasonalEvent? get season => _season;

  /// Something is happening that wants smoother drawing: one of Mochi's or Patch's moments, or a moment together.
  bool get busy => world.interaction != null || world.pet.isPlayingOneShot || world.companion.isPlayingOneShot;

  /// The moment is yours: Mochi answering your pet, play or treat, or what you asked (drawn every display frame).
  bool get yours => world.pet.isPlayingOneShot && world.pet.current.priority == AnimationPriority.user;

  /// Mochi is asleep and Patch too (or away): the room barely moves.
  bool get napping => world.petAsleep && (!world.companionPresent || world.companion.base == CompanionAnimation.sleep) && !busy;

  /// What Mochi or Patch is saying (the iPhone's room shows `world.activeSpeech`). Nothing makes the phone's world
  /// speak today, as on the iPhone; the room's own bubbles (what Mochi hears, the computer's answers) come first.
  ValueListenable<String?> get saying => _saying;

  // MARK: When it ticks

  /// The room can be seen (the app in front, the room on screen) or not: the world ticks only while it can.
  void roomVisible(bool visible) {
    if (_disposed || visible == _roomVisible) return;
    _roomVisible = visible;
    if (visible) {
      tick();
      _ticker ??= Timer.periodic(tickInterval, (_) => tick());
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Android's "Remove animations": Mochi and Patch move as the Mac's do under Reduce Motion (drawn from the next
  /// frame; listeners hear at the next tick).
  void setReducedMotion(bool reduced) => world.setSystemReducedMotion(reduced);

  /// One step (the timer's; tests step it themselves).
  void tick() {
    if (_disposed) return;
    world.tick();
    _refreshSeason();
    _changed();
  }

  // MARK: Following the computer

  void _follow() {
    if (_disposed) return;
    final look = model.look;
    if (look != null) {
      final settings = world.settings;
      if (settings.petName != look.petName || settings.companionName != look.companionName) {
        world.settings = settings.copyWith(petName: look.petName, companionName: look.companionName);
      }
    }
    _refreshSeason();
    final claude = model.claude;
    final next = claude == null ? const _Mirror('none') : _Mirror(claude.phase, claude.category, claude.resting);
    if (next != _mirror) {
      final claudeChanged = next.phase != _mirror.phase || next.category != _mirror.category;
      _mirror = next;
      if (claudeChanged) {
        _log('claude on ${model.host.yours}: ${next.phase} ${next.category ?? ''}');
        _play(next, quiet: _quiet);
      }
    }
    if (claude == null) {
      // No room yet, or a new one: its first state sets the scene again.
      _quiet = true;
    } else {
      _quiet = false;
      // Mochi sleeps here while the computer rests, and wakes when it's in use again.
      world.updateSystem(SystemActivity(idleSeconds: claude.resting ? 86400 : 0));
    }
    _changed();
  }

  /// Mirrors the computer's Claude activity as simulated events (never kept, never counted): the iPhone's `play`.
  void _play(_Mirror mirror, {required bool quiet}) {
    final delivery = quiet ? EventDelivery.restored : EventDelivery.live;
    void send(String name, String session, {String? tool, String? category, String? toolUse, String? notification}) =>
        _send(name, session, delivery, tool: tool, category: category, toolUse: toolUse, notification: notification);
    String ensureSession() {
      final known = _mirrorSession;
      if (known != null) return known;
      final session = 'mac-mirror-${_hex(8)}';
      _mirrorSession = session;
      send('SessionStart', session);
      return session;
    }

    // The tool before this state is done by now.
    final running = _tool;
    if (running != null) {
      running.timer.cancel();
      running.finish();
    }
    switch (mirror.phase) {
      case 'none':
        final session = _mirrorSession;
        if (session != null) send('SessionEnd', session);
        _mirrorSession = null;
        _inTurn = false;
      case 'working':
        final session = ensureSession();
        if (!_inTurn) {
          send('UserPromptSubmit', session);
          _inTurn = true;
        }
        if (mirror.category != 'think') {
          final tool = toolFor(mirror.category);
          final toolUse = 'mirror-tool-$_eventCount';
          send('PreToolUse', session, tool: tool, category: mirror.category, toolUse: toolUse);
          void finish() {
            _tool = null;
            send('PostToolUse', session, tool: tool, category: mirror.category, toolUse: toolUse);
          }

          _tool = (
            timer: Timer(toolDelay, () {
              finish();
              _changed();
            }),
            finish: finish,
          );
        }
      case 'waiting':
        send('Notification', ensureSession(), notification: 'permission_prompt');
      case 'done':
        send('Stop', ensureSession());
        _inTurn = false;
      case 'error':
        send('StopFailure', ensureSession());
        _inTurn = false;
      default:
        ensureSession();
    }
  }

  void _send(String name, String session, EventDelivery delivery, {String? tool, String? category, String? toolUse, String? notification}) {
    if (_disposed) return;
    _eventCount += 1;
    world.ingestWire({
      'v': 1,
      'id': 'mirror-$_eventCount-${_hex(6)}',
      'ts': _clock().microsecondsSinceEpoch / 1e6,
      'origin': 'simulator',
      'event': name,
      'session': session,
      'project': model.host.yoursCapitalized,
      'projectKey': 'macmirror0',
      if (tool != null) ...{'tool': tool, 'toolCategory': category == 'think' ? 'other' : (category ?? 'edit'), 'toolUseId': ?toolUse},
      if (notification != null) ...{'notificationType': notification, 'message': 'Claude needs you'},
      if (name == 'StopFailure') 'reason': 'server_error',
    }, delivery: delivery);
  }

  /// The tool a mirrored session "uses" for a category, so Patch picks the matching work (Swift `ClaudeMirror.tool`).
  static String toolFor(String? category) => switch (category) {
    'read' => 'Read',
    'search' => 'Grep',
    'shell' => 'Bash',
    'web' => 'WebFetch',
    'agent' => 'Task',
    _ => 'Edit',
  };

  String _hex(int length) => List.generate(length, (_) => _random.nextInt(16).toRadixString(16)).join();

  // MARK: Petting, play and treats; what you asked

  /// A pet, play or treat (here, or from the computer: PocketModel sends the phone's own and drops repeats and old
  /// ones), and how a request is going.
  void _cue(PetCue cue) {
    if (_disposed) return;
    switch (cue) {
      case PetCue.pet:
        world.interact(PetInteraction.pet);
      case PetCue.play:
        world.interact(PetInteraction.play);
      case PetCue.treat:
        world.interact(PetInteraction.treat);
      case PetCue.sending:
        world.playPet(PetAnimation.nod);
      case PetCue.working:
        world.playPet(PetAnimation.lookAround, priority: AnimationPriority.ambient);
      case PetCue.replied:
        world.playPet(PetAnimation.happyBounce);
      case PetCue.failed:
        world.playPet(PetAnimation.concerned);
    }
    _changed();
  }

  // MARK: Holidays

  /// The computer's holiday settings for today (worked out at most once a minute, as the iPhone's `SeasonState`).
  void _refreshSeason() {
    final now = _clock();
    final settings = SeasonalSettings.fromJson(model.look?.seasonal);
    final key = (now.millisecondsSinceEpoch ~/ 60000, settings);
    if (key == _seasonKey) return;
    _seasonKey = key;
    _season = SeasonCalendar.event(now, settings: settings, calendar: _calendar);
  }

  // MARK: What the room says

  /// What Mochi and Patch are doing, in words (the room's label for TalkBack).
  String describe() {
    final pet = world.settings.petName;
    final patch = world.settings.companionName;
    final mochi = switch (world.status.mood) {
      WorldMood.sleeping => '$pet is napping',
      WorldMood.watching => '$pet is watching Claude work',
      WorldMood.waiting => 'Claude needs you',
      WorldMood.concerned => 'Claude hit a snag',
      WorldMood.celebrating => 'Claude finished',
      WorldMood.content || WorldMood.offline || WorldMood.paused => '$pet is relaxing',
    };
    final together = world.interaction;
    if (together != null) return '$mochi. $patch and $pet: ${together.id.title.toLowerCase()}';
    final companion = switch (world.companion.base) {
      CompanionAnimation.idleAtDesk => '$patch is at his desk',
      CompanionAnimation.thinking => '$patch is thinking',
      CompanionAnimation.typing => '$patch is typing at his desk',
      CompanionAnimation.reading => '$patch is reading',
      CompanionAnimation.searching => '$patch is searching',
      CompanionAnimation.runningCommand => '$patch is watching a command run',
      CompanionAnimation.browsing => '$patch is browsing the web',
      CompanionAnimation.delegating => '$patch is handing work to helpers',
      CompanionAnimation.waiting => '$patch is waiting for you',
      CompanionAnimation.rest => '$patch is resting',
      CompanionAnimation.sleep => '$patch is napping at his desk',
      CompanionAnimation.absent => '$patch is away',
      final other => '$patch is ${other.title.toLowerCase()}',
    };
    return '$mochi. $companion';
  }

  // MARK: Telling the room

  /// What the room shows changed (a new moment, a nap, a bubble, the holiday): listeners hear about it once, not
  /// every tick.
  void _changed() {
    if (_disposed) return;
    final speech = world.activeSpeech?.text;
    if (speech != _saying.value) _saying.value = speech;
    final pet = world.pet;
    final companion = world.companion;
    final signature = (
      pet.current.token,
      pet.base,
      companion.current.token,
      companion.base,
      world.interaction?.startedAt,
      world.companionPresent,
      world.petAsleep,
      world.status.mood,
      world.settings.petName,
      world.settings.companionName,
      world.reducedMotion,
      _season,
    );
    if (signature == _signature) return;
    _signature = signature;
    notifyListeners();
  }

  /// Development builds only, and never what Claude is working on.
  void _log(String message) {
    if (kDebugMode) debugPrint('Mochi: $message');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    _tool?.timer.cancel();
    _tool = null;
    model.removeListener(_follow);
    unawaited(_cues.cancel());
    _saying.dispose();
    super.dispose();
  }
}
