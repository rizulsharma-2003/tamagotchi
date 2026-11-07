// W11, Mochi talks. Port of Sources/TamagotchiCore/Features/SpeechLines.swift (the occasions, the curated lines, line
// choice, pacing per chattiness and the clean-up of generated lines) and of the rules in
// Sources/App/Features/Speech/SpeechController.swift (when to speak: Claude's events, petting, greetings once per part
// of the day, waking up, sleepy mumbles and idle musings), as `SpeechDirector`. Fresh lines (Apple Intelligence on the
// Mac, Claude Haiku on Windows) come in through a hook; nothing here talks to a model.

import 'dart:async';
import 'dart:math' as math;

import '../events/events.dart';
import '../events/sessions.dart';
import '../model/random.dart';
import '../progress/progress.dart';
import '../world/settings.dart';
import '../world/world.dart';
import 'text.dart';

/// How much a line matters: quiet chattiness keeps only [high].
enum SpeechImportance { low, medium, high }

/// Moments the characters may say something about.
enum SpeechOccasion {
  morning,
  afternoon,
  evening,
  lateNight,
  sessionStarted,
  promptSubmitted,
  turnCompleted,
  turnFailed,
  toolFailed,
  buildPassed,
  testsPassed,
  buildFailed,
  testsFailed,
  waitingForUser,
  permission,
  subagentStarted,
  sessionEnded,
  petted,
  played,
  treat,
  wokeUp,
  sleepy,
  idle;

  SpeechImportance get importance => switch (this) {
    waitingForUser || permission || turnCompleted || buildPassed || testsPassed => SpeechImportance.high,
    promptSubmitted || sleepy || idle => SpeechImportance.low,
    _ => SpeechImportance.medium,
  };

  /// What happened, in plain words, for asking a model for a fresh line. Never mentions projects, files, commands or
  /// anything the user typed.
  String get situation => switch (this) {
    morning => 'It is morning and the user just showed up.',
    afternoon => 'It is the afternoon.',
    evening => 'It is the evening.',
    lateNight => 'It is very late at night and the user is still at the computer.',
    sessionStarted => 'Claude, the coding assistant, just started a work session.',
    promptSubmitted => 'The user just gave Claude a new task.',
    turnCompleted => 'Claude just finished a task.',
    turnFailed => "Claude's task stopped with an error.",
    toolFailed => "One of Claude's steps hit an error, and Claude keeps working.",
    buildPassed => 'The build just passed.',
    testsPassed => 'All the tests just passed.',
    buildFailed => 'The build just failed.',
    testsFailed => 'Some tests just failed.',
    waitingForUser => 'Claude is waiting for the user to answer a question.',
    permission => 'Claude is asking the user for permission to continue.',
    subagentStarted => 'Claude just called in helper agents.',
    sessionEnded => "Claude's work session just ended.",
    petted => 'The user is petting the cat.',
    played => 'The user is playing with the cat.',
    treat => 'The user just gave the cat a treat.',
    wokeUp => 'The cat just woke up from a nap.',
    sleepy => 'The cat is asleep, mumbling in its dreams.',
    idle => 'Nothing is happening; the cat is just hanging around.',
  };

  /// The occasion for a real Claude Code event, if it deserves a word.
  static SpeechOccasion? forEvent(CompanionEvent event) {
    if (event.buildTestOutcome case final outcome?) {
      return switch ((outcome.kind, outcome.passed)) {
        (CommandKind.build, true) => buildPassed,
        (CommandKind.test, true) => testsPassed,
        (CommandKind.build, false) => buildFailed,
        (CommandKind.test, false) => testsFailed,
      };
    }
    return switch (event.kind) {
      EventKind.sessionStarted => sessionStarted,
      EventKind.promptSubmitted => promptSubmitted,
      EventKind.toolFailed => event.interrupted ? null : toolFailed,
      EventKind.permissionRequested => permission,
      EventKind.attentionNeeded => event.attention == AttentionKind.permission ? permission : waitingForUser,
      EventKind.subagentStarted => subagentStarted,
      EventKind.turnCompleted => turnCompleted,
      EventKind.turnFailed => turnFailed,
      EventKind.sessionEnded => sessionEnded,
      _ => null,
    };
  }

  /// The greeting for a local hour (0–23).
  static SpeechOccasion greeting(int hour) {
    if (hour >= 5 && hour < 12) return morning;
    if (hour >= 12 && hour < 17) return afternoon;
    if (hour >= 17 && hour < 23) return evening;
    return lateNight;
  }

  /// The occasion for petting, play or a treat.
  static SpeechOccasion forInteraction(PetInteraction kind) => switch (kind) {
    PetInteraction.pet => petted,
    PetInteraction.play => played,
    PetInteraction.treat => treat,
  };
}

/// One line and who says it.
class SpeechLine {
  const SpeechLine(this.speaker, this.text);
  final SpeechSpeaker speaker;
  final String text;

  @override
  bool operator ==(Object other) => other is SpeechLine && other.speaker == speaker && other.text == text;

  @override
  int get hashCode => Object.hash(speaker, text);

  @override
  String toString() => '${speaker.name}: $text';
}

/// Hand-written lines for every occasion: the pet is bubbly, the companion a focused little engineer.
abstract final class SpeechLines {
  static List<SpeechLine> lines(SpeechOccasion occasion) {
    List<SpeechLine> pet(List<String> texts) => [for (final t in texts) SpeechLine(SpeechSpeaker.pet, t)];
    List<SpeechLine> claude(List<String> texts) => [for (final t in texts) SpeechLine(SpeechSpeaker.companion, t)];
    return switch (occasion) {
      SpeechOccasion.morning => pet(['Good morning! ☀️', 'Morning! Coffee first?', 'Rise and shine!', 'Ready for a good day?']),
      SpeechOccasion.afternoon => pet(['Good afternoon!', "Snack o'clock?", 'Halfway there!', 'Afternoon stretch? 🐾']),
      SpeechOccasion.evening => pet(['Good evening!', 'Cozy evening coding?', "Don't forget dinner!", 'Evening already?']),
      SpeechOccasion.lateNight => pet(["It's late… bed soon?", 'Night owl mode 🦉', 'Yawn… still coding?', 'The stars are out ✨']),
      SpeechOccasion.sessionStarted =>
        pet(["Claude's here!", 'Yay, Claude!']) + claude(['Hi! Ready when you are.', "Let's build something.", 'Booting up… hello!']),
      SpeechOccasion.promptSubmitted => claude(['On it!', 'Ooh, a new task.', 'Let me think…', 'Reading the request…']),
      SpeechOccasion.turnCompleted =>
        pet(["Claude's done, high five!", 'Done! 🎉', 'Nice work!']) + claude(['All done!', 'Finished! ✨', 'Ta-da!']),
      SpeechOccasion.turnFailed => claude(["Hmm, that didn't work.", 'Let me try another way.']) + pet(["We'll get it next time!"]),
      SpeechOccasion.toolFailed => claude(['Oops, an error.', 'Hmm… not quite.', 'Let me fix that.']),
      SpeechOccasion.buildPassed => pet(['Green build! 💚']) + claude(['Build passed!', 'It compiles! ✨']),
      SpeechOccasion.testsPassed => pet(['All tests pass! ✅', 'Green across the board!']) + claude(['Tests are green!']),
      SpeechOccasion.buildFailed => claude(["Build's broken… on it.", 'Red build. Fixing!']) + pet(["You've got this!"]),
      SpeechOccasion.testsFailed => claude(['Red tests… on it.', 'A test failed. Looking.']) + pet(["Don't worry, we've got this."]),
      SpeechOccasion.waitingForUser => pet(['Claude needs you!', 'Psst… your turn!', 'Claude has a question.']),
      SpeechOccasion.permission => claude(['May I? Need your OK.', 'Waiting for your approval.']) + pet(["Claude's asking permission!"]),
      SpeechOccasion.subagentStarted => claude(['Calling in helpers!', 'Teamwork time!', "Mini-me's, assemble!"]),
      SpeechOccasion.sessionEnded => claude(['See you soon!', 'Bye for now! 👋']) + pet(['Bye, Claude!']),
      SpeechOccasion.petted => pet(['Purr…', 'Hehe, that tickles!', 'More scritches?', '♥ ♥ ♥', 'Mrrrp!']),
      SpeechOccasion.played => pet(['Again! Again!', 'Catch me!', 'Wheee!', 'Best game ever!']),
      SpeechOccasion.treat => pet(['Yum!', 'Nom nom nom', 'My favourite!', 'Thank you! ♥']),
      SpeechOccasion.wokeUp => pet(["Oh! I'm awake!", 'Was I snoring?', 'Did I miss anything?']),
      SpeechOccasion.sleepy => pet(['zzz… cookies…', 'five more minutes…', 'mmm… yarn…', 'zzz…', '…tuna…']),
      SpeechOccasion.idle => pet(["I wonder what Claude's building.", 'Is it snack time?', 'La la la ♪', 'Pet me? 👀', '*stretches*']),
    };
  }

  /// Who speaks for an occasion (the first line's speaker), e.g. for asking a model in the right voice.
  static SpeechSpeaker speaker(SpeechOccasion occasion) => lines(occasion).first.speaker;

  /// A line for the occasion, not one of the [recent] ones when there is a choice. [seed] is a UInt64's bit pattern;
  /// the same seed picks the same line as the Mac.
  static SpeechLine? pick(SpeechOccasion occasion, int seed, {List<String> avoiding = const []}) {
    final all = lines(occasion);
    final fresh = all.where((l) => !avoiding.contains(l.text)).toList();
    final pool = fresh.isEmpty ? all : fresh;
    if (pool.isEmpty) return null;
    // Swift mixes the seed with SplitMix64's finalizer: exactly SplitMix64(seed)'s first output.
    return pool[unsignedMod(SplitMix64(seed).next(), pool.length)];
  }

  static const _refusals = ['sorry', 'as an ai', "i can't", 'i cannot', 'language model', 'assistant'];

  /// Cleans a generated line: one short sentence, no quotes, nothing that sounds like a refusal. Null when nothing
  /// usable is left.
  static String? sanitize(String raw, {int maxLength = 44}) {
    final buffer = StringBuffer();
    for (final character in characters(raw)) {
      if (isNewlineCharacter(character)) {
        if (buffer.isNotEmpty) break;
        continue;
      }
      buffer.write(character);
    }
    var text = trimScalars(buffer.toString(), (r) => isWhitespaceOrNewline(r) || '"\'“”‘’*'.runes.contains(r));
    final lowered = text.toLowerCase();
    if (text.isEmpty || _refusals.any(lowered.contains)) return null;
    final chars = characters(text);
    if (chars.length > maxLength) {
      final cut = chars.take(maxLength).toList();
      final space = cut.lastIndexOf(' ');
      if (space < 0) return null;
      text = '${trimScalars(cut.take(space).join(), isPunctuation)}…';
    }
    return text;
  }

  /// How long a bubble stays up for [text]: 2 s plus a little per character, between 3.2 and 6 seconds.
  static double duration(String text) => math.min(6, math.max(3.2, 2 + characterCount(text) * 0.11));

  /// The occasions fresh lines are written for (the Mac's `freshOccasions`).
  static const List<SpeechOccasion> freshOccasions = [
    SpeechOccasion.morning,
    SpeechOccasion.afternoon,
    SpeechOccasion.evening,
    SpeechOccasion.lateNight,
    SpeechOccasion.sessionStarted,
    SpeechOccasion.turnCompleted,
    SpeechOccasion.testsPassed,
    SpeechOccasion.waitingForUser,
    SpeechOccasion.petted,
    SpeechOccasion.played,
    SpeechOccasion.treat,
    SpeechOccasion.sleepy,
    SpeechOccasion.idle,
  ];
}

/// When a line may be said: each chattiness level has its own pace; important lines get through sooner.
class SpeechPacing {
  const SpeechPacing(this.chattiness);
  final Chattiness chattiness;

  /// Whether [occasion] may speak [since] seconds after the last line.
  bool allows(SpeechOccasion occasion, double since) {
    final importance = occasion.importance;
    switch (chattiness) {
      case Chattiness.quiet:
        return importance == SpeechImportance.high && since >= 20;
      case Chattiness.normal:
        if (importance == SpeechImportance.high) return since >= 8;
        return since >= (importance == SpeechImportance.medium ? 30 : 90);
      case Chattiness.chatty:
        return since >= (importance == SpeechImportance.high ? 5 : 12);
    }
  }

  /// Seconds between spontaneous idle musings (null: never).
  double? get idleInterval => switch (chattiness) {
    Chattiness.quiet => null,
    Chattiness.normal => 25 * 60,
    Chattiness.chatty => 9 * 60,
  };

  /// Seconds between sleepy mumbles while the pet naps (null: never).
  double? get sleepInterval => switch (chattiness) {
    Chattiness.quiet => null,
    Chattiness.normal => 7 * 60,
    Chattiness.chatty => 3 * 60,
  };
}

/// What to ask a model for one fresh line (the Mac's `FreshLineWriter` prompt): [instructions] go in the system
/// prompt, [prompt] is the request. Run the answer through [SpeechLines.sanitize]. Only the kind of moment is sent:
/// never projects, files or anything the user typed.
class FreshLinePrompt {
  FreshLinePrompt._(this.occasion, this.speaker, this.instructions, this.prompt);

  /// [home] is where Mochi lives on this computer ("the Mac menu bar" on the Mac, "the Windows taskbar" on a PC).
  factory FreshLinePrompt(
    SpeechOccasion occasion, {
    required String petName,
    required String companionName,
    String home = 'the Mac menu bar',
  }) {
    final speaker = SpeechLines.speaker(occasion);
    final persona = speaker == SpeechSpeaker.pet
        ? 'You are $petName, a playful, affectionate little cat who lives in $home.'
        : 'You are $companionName, a cheerful little pixel-art creature who helps people write code.';
    return FreshLinePrompt._(
      occasion,
      speaker,
      '$persona Reply with one very short, warm, playful line of at most eight words, said out loud in a speech bubble. '
          'No quotes, no hashtags, no names.',
      '${occasion.situation} What do you say?',
    );
  }

  final SpeechOccasion occasion;
  final SpeechSpeaker speaker;
  final String instructions;
  final String prompt;
}

/// Writes fresh lines for some occasions (on Windows: Claude Haiku through `claude -p`, one [FreshLinePrompt] each).
/// Return what came out (sanitized); missing occasions are fine.
typedef FreshLineWriter =
    Future<Map<SpeechOccasion, List<SpeechLine>>> Function(
      List<SpeechOccasion> occasions, {
      required String petName,
      required String companionName,
    });

/// Decides when Mochi and Patch say something, as the Mac's SpeechController does, and puts the line in the world's
/// speech bubble. Wire it to the world's effects: `worldDidReact` → [react], `userDidInteract` → [interacted], and
/// call [tick] a couple of times a second (the world's 4 Hz tick is fine). Deterministic for a [seed] and the world's
/// clocks (the Mac uses the system's random numbers here).
class SpeechDirector {
  SpeechDirector(this.world, {int? seed, this.writer, this.windowVisible = false})
    : _rng = SplitMix64((seed ?? world.seed) ^ 0x5350454543484D4F),
      _wasAsleep = world.petAsleep;

  final MochiWorld world;

  /// Writes fresh lines every couple of hours while `settings.speechFreshLines` is on (null: curated lines only).
  FreshLineWriter? writer;

  /// Mochi's window is open, so the user is clearly here: greetings wait for it (the Mac's popover).
  bool windowVisible;

  final SplitMix64 _rng;
  double _lastSpokeAt = double.negativeInfinity;
  final List<String> _recent = [];
  String? _greeted;
  double? _nextIdleAt;
  double? _nextSleepAt;
  bool _wasAsleep;
  double _lastCheck = 0;
  final Map<SpeechOccasion, List<SpeechLine>> _fresh = {};
  DateTime? _lastRefill;
  bool _writing = false;

  /// Seconds between fresh-line refills.
  static const double refillInterval = 2 * 3600;

  /// The last lines said (up to 8), which [SpeechLines.pick] avoids.
  List<String> get recent => List.unmodifiable(_recent);

  /// Fresh lines waiting to be used, per occasion (at most 3 each).
  Map<SpeechOccasion, List<SpeechLine>> get freshLines => {for (final e in _fresh.entries) e.key: List.unmodifiable(e.value)};

  // MARK: Triggers

  /// A live Claude event went through the world (`WorldEffects.worldDidReact`). Background sessions only speak up for
  /// what really matters.
  void react(CompanionEvent event, SessionSnapshot? session) {
    final occasion = SpeechOccasion.forEvent(event);
    if (occasion == null) return;
    final primary = world.primarySession;
    if (session != null && primary != null && session.id != primary.id && occasion.importance.index < SpeechImportance.high.index) return;
    say(occasion);
  }

  /// The user petted, played with or fed Mochi (`WorldEffects.userDidInteract`): a word about two times in three.
  void interacted(PetInteraction kind) {
    final occasion = SpeechOccasion.forInteraction(kind);
    if (_rng.nextUnit() >= 0.65) return;
    say(occasion);
  }

  /// Says a line for [occasion] if speech is on, the pace allows it and the speaker is around. Returns the line said.
  SpeechLine? say(SpeechOccasion occasion) {
    final settings = world.settings;
    if (!settings.speechEnabled || settings.pauseReactions) return null;
    final now = world.now;
    if (!SpeechPacing(settings.chattiness).allows(occasion, now - _lastSpokeAt)) return null;
    final line = _freshLine(occasion) ?? SpeechLines.pick(occasion, _rng.next(), avoiding: _recent);
    if (line == null) return null;
    if (line.speaker == SpeechSpeaker.companion && !world.companionPresent) return null;
    if (line.speaker == SpeechSpeaker.pet && world.adventureActive) return null;
    _lastSpokeAt = now;
    _recent.add(line.text);
    if (_recent.length > 8) _recent.removeAt(0);
    world.say(line.text, speaker: line.speaker, duration: SpeechLines.duration(line.text));
    return line;
  }

  // MARK: Ticking

  /// Clears a bubble whose time is up and, every 5 seconds, greets, mumbles in its sleep or muses (and refills fresh
  /// lines when they're due).
  void tick() {
    final now = world.now;
    final bubble = world.speech;
    if (bubble != null && !bubble.isVisible(now)) world.clearSpeech(bubble.id);
    if (now - _lastCheck < 5) return;
    _lastCheck = now;
    _spontaneous(now);
    refillFreshLines();
  }

  void _spontaneous(double now) {
    final settings = world.settings;
    if (!settings.speechEnabled || settings.pauseReactions) return;
    final pacing = SpeechPacing(settings.chattiness);
    final date = world.date;
    final calendar = world.calendar;
    // Greet once per part of the day, when the user is clearly here (the window is open).
    final occasion = SpeechOccasion.greeting(calendar.hour(date));
    final period = '${calendar.startOfDay(date).millisecondsSinceEpoch ~/ 1000}-${occasion.name}';
    if (windowVisible && _greeted != period) {
      _greeted = period;
      _lastSpokeAt = double.negativeInfinity;
      say(occasion);
      return;
    }
    if (_wasAsleep && !world.petAsleep && _rng.nextUnit() < 0.5) say(SpeechOccasion.wokeUp);
    _wasAsleep = world.petAsleep;
    final working = world.status.companionWorking;
    final sleepInterval = pacing.sleepInterval;
    final idleInterval = pacing.idleInterval;
    if (world.petAsleep && sleepInterval != null) {
      if (_nextSleepAt case final next? when now >= next) say(SpeechOccasion.sleepy);
      if (_nextSleepAt == null || now >= _nextSleepAt!) _nextSleepAt = now + sleepInterval * _rng.nextIn(0.7, 1.3);
    } else if (!working && idleInterval != null) {
      if (_nextIdleAt case final next? when now >= next) say(SpeechOccasion.idle);
      if (_nextIdleAt == null || now >= _nextIdleAt!) _nextIdleAt = now + idleInterval * _rng.nextIn(0.7, 1.3);
    }
  }

  // MARK: Fresh lines

  SpeechLine? _freshLine(SpeechOccasion occasion) {
    final lines = _fresh[occasion];
    if (!world.settings.speechFreshLines || lines == null || lines.isEmpty || _rng.nextUnit() >= 0.5) return null;
    return lines.removeAt(0);
  }

  /// Adds fresh lines (keeping the newest 3 per occasion). [refillFreshLines] calls it with the writer's answer.
  void addFreshLines(Map<SpeechOccasion, List<SpeechLine>> lines) {
    for (final MapEntry(key: occasion, value: added) in lines.entries) {
      final all = [...?_fresh[occasion], ...added];
      _fresh[occasion] = all.sublist(all.length > 3 ? all.length - 3 : 0);
    }
  }

  /// Asks the [writer] for new lines every couple of hours (when speech and fresh lines are on). Returns the request
  /// while one runs, so tests can wait for it.
  Future<void>? refillFreshLines() {
    final settings = world.settings;
    final writer = this.writer;
    if (!settings.speechEnabled || !settings.speechFreshLines || writer == null || _writing) return null;
    final date = world.date;
    if (_lastRefill case final last? when date.difference(last).inMicroseconds / 1e6 < refillInterval) return null;
    _lastRefill = date;
    _writing = true;
    return Future(
      () => writer(SpeechLines.freshOccasions, petName: settings.petName, companionName: settings.companionName),
    ).then(addFreshLines, onError: (Object _) {}).whenComplete(() => _writing = false);
  }
}
