// Sticky notes from Mochi (docs/SPRINT_2.md X9): left on the desktop for green tests, Claude finishing or needing you
// while you're away, a stretch break and streaks, in Mochi's voice naming your PC; at most three, pinned ones kept
// (even after a restart), dismissed with the ×, a click opening Mochi's window, dragged elsewhere; unpinned ones leave
// after a quarter of an hour; only when Mischief may (hidden meanwhile), with no timer while nobody can see the screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_wire/mochi_wire.dart' show WireEvent;
import 'package:mochi_desktop/src/core/json_store.dart';
import 'package:mochi_desktop/src/core/mischief.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show QuietHours;
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/platform/native_stage.dart';
import 'package:mochi_desktop/src/ui/stage/celebrations.dart' show CelebrationKind;
import 'package:mochi_desktop/src/ui/stage/mischief_stage.dart';
import 'package:mochi_desktop/src/ui/stage/sticky_notes.dart';

import 'support/fake_stage.dart';
import 'support/fakes.dart';

void main() {
  late TestDesktop t;
  late FakeNativeStage stage;
  MischiefStage? stageOfMischief;
  late MemoryJsonStore store;
  var now = DateTime(2026, 11, 8, 15);
  var fullScreen = false;
  var opened = 0;

  setUp(() {
    now = DateTime(2026, 11, 8, 15);
    fullScreen = false;
    opened = 0;
    store = MemoryJsonStore();
    t = TestDesktop.make(clock: () => now, fullScreen: () => fullScreen, activity: const SystemActivity(idleSeconds: 1));
    t.desktop.rhythm.sample();
    stage = FakeNativeStage();
  });

  tearDown(() async {
    stageOfMischief?.dispose();
    stageOfMischief = null;
    await t.dispose();
  });

  StickyNotes notes() => stageOfMischief!.notes;

  void begin({bool on = true}) {
    stageOfMischief = MischiefStage(
      desktop: t.desktop,
      stage: stage,
      displays: FakeDisplays([FakeDisplays.main1080, FakeDisplays.side1440]),
      cursor: () => (900, 500),
      onOpen: () => opened++,
      notesStore: store,
      clock: testSeconds,
    );
    t.desktop.mischief.start();
    stageOfMischief!.start();
    if (on) t.desktop.settings.mischief = const MischiefSettings(enabled: true);
  }

  /// Lets the notes' pictures be drawn (real time), then their fades play.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> done(WidgetTester tester) async {
    stageOfMischief!.celebrations.stop();
    stageOfMischief!.notes.stop();
    t.desktop.mischief.stop();
    await tester.pump();
  }

  /// A click on [note] at [point] (logical pixels from its top-left).
  void click(StickyNote note, Offset point) {
    final actor = notes().actorOf(note)!;
    final sprite = stageOfMischief!.notes.sprites.lookup('note ${note.id} ${note.kind.name} ${note.pinned} null ${note.title} ${note.detail}');
    final ox = sprite?.originX ?? 0, oy = sprite?.originY ?? 0;
    final x = ox + point.dx.round(), y = oy + point.dy.round();
    stage
      ..point(actor, StagePointerKind.down, x: x, y: y)
      ..point(actor, StagePointerKind.up, x: x, y: y);
  }

  testWidgets('green tests: a note in Mochi’s voice naming your PC, at the top right of the main display', (tester) async {
    begin();
    var at = now;
    WireEvent event(String name, {String? tool}) {
      at = at.add(const Duration(seconds: 3));
      return hook(name, project: 'mac-Tamagotchi', tool: tool, toolUseId: tool == null ? null : 'u-1', at: at);
    }

    t.desktop.receive(event('SessionStart'));
    t.desktop.receive(event('UserPromptSubmit'));
    t.desktop.receive(event('PreToolUse', tool: 'Bash'));
    // A real test run that passed (its exit status trustworthy), then the turn ends: G2's green tests.
    t.desktop.receive(
      event('PostToolUse', tool: 'Bash')
        ..commandKind = 'test'
        ..commandReliable = true
        ..exitCode = 0,
    );
    t.desktop.receive(event('Stop'));
    expect(stageOfMischief!.celebrations.playing, CelebrationKind.confetti, reason: 'confetti too');
    await settle(tester);
    final note = notes().notes.single;
    expect(note.title, 'Claude finished the tests ✓');
    expect(note.detail, 'All green in mac-Tamagotchi on your PC.');
    final shot = stage.showing[notes().actorOf(note)]!;
    expect(shot.clickThrough, isFalse, reason: 'a note takes clicks');
    expect(shot.alpha, 255, reason: 'faded in');
    expect(shot.left, greaterThan(1920 - 300));
    expect(shot.top, lessThan(40));
    await done(tester);
  });

  testWidgets('Claude finishing or needing you while you’re away leaves a note; while you’re here, nothing', (tester) async {
    begin();
    t.desktop.receive(hook('SessionStart', at: now));
    // Claude's moments as Reactions passes them to the views (desktop.start() wires the sessions to it in the app).
    t.desktop.cue(PetCue.finished);
    await tester.pump();
    expect(notes().notes, isEmpty, reason: 'you were here');
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 400));
    t.desktop.cue(PetCue.finished);
    await tester.pump();
    expect(notes().notes.map((note) => note.kind), [NoteKind.finishedAway]);
    expect(notes().notes.single.detail, 'web is ready for you on your PC.');
    t.desktop.cue(PetCue.needsYou);
    await tester.pump();
    expect(notes().notes.map((note) => note.kind), [NoteKind.finishedAway, NoteKind.needsYouAway]);
    expect(notes().notes.last.title, 'Claude needs you');
    await done(tester);
  });

  testWidgets('at most three: the oldest unpinned goes, the same kind replaces; three pinned leave no room', (tester) async {
    begin();
    final a = notes().leave(NoteKind.stretch, NoteWords.stretch)!;
    final b = notes().leave(NoteKind.finishedAway, NoteWords.finishedAway(null))!;
    final c = notes().leave(NoteKind.needsYouAway, NoteWords.needsYouAway(null))!;
    notes().leave(NoteKind.testsPassed, NoteWords.testsPassed(null));
    expect(notes().notes, hasLength(3));
    expect(notes().notes, isNot(contains(a)), reason: 'the oldest went');
    notes().leave(NoteKind.finishedAway, NoteWords.finishedAway('web'));
    expect(notes().notes.where((note) => note.kind == NoteKind.finishedAway), hasLength(1));
    expect(notes().notes, isNot(contains(b)), reason: 'replaced by the newer one');
    for (final note in List.of(notes().notes)) {
      notes().togglePin(note);
    }
    expect(notes().leave(NoteKind.stretch, NoteWords.stretch), isNull, reason: 'three pinned: no room');
    expect(notes().notes, contains(c));
    await done(tester);
  });

  testWidgets('pin keeps it (even after a restart); × dismisses; a click opens Mochi’s window; a drag moves it', (tester) async {
    begin();
    final note = notes().leave(NoteKind.finishedAway, NoteWords.finishedAway('web'))!;
    await settle(tester);
    click(note, NoteArt.pinRect.center);
    expect(note.pinned, isTrue);
    expect(store.json, isA<List<Object?>>().having((list) => list.length, 'pinned notes', 1));
    await settle(tester);
    // A drag moves it.
    final actor = notes().actorOf(note)!;
    final before = stage.showing[actor]!;
    stage
      ..point(actor, StagePointerKind.down, x: 100, y: 60, screenX: 1700, screenY: 70)
      ..point(actor, StagePointerKind.move, x: 60, y: 260, screenX: 1660, screenY: 270)
      ..point(actor, StagePointerKind.up, x: 60, y: 260, screenX: 1660, screenY: 270);
    await settle(tester);
    expect(stage.showing[actor]!.left - before.left, -40);
    expect(stage.showing[actor]!.top - before.top, 200);
    expect(opened, 0, reason: 'a drag isn’t a click');
    // A restart: the pinned note is back, where it was dragged.
    final saved = store.json;
    stageOfMischief!.notes.stop();
    final again = StickyNotes(
      stage: stage,
      cast: stageOfMischief!.cast,
      gate: t.desktop.mischief,
      rhythm: t.desktop.rhythm,
      displays: FakeDisplays(),
      settings: t.desktop.settings,
      store: MemoryJsonStore(saved),
    )..start();
    expect(again.notes.single.title, note.title);
    expect(again.notes.single.pinned, isTrue);
    expect(again.notes.single.movedTo, note.movedTo);
    again.dispose();
    await done(tester);
  });

  testWidgets('× dismisses it (with a fade); a click on the note opens Mochi’s window and lets an unpinned note go', (tester) async {
    begin();
    final first = notes().leave(NoteKind.stretch, NoteWords.stretch)!;
    final second = notes().leave(NoteKind.testsPassed, NoteWords.testsPassed(null))!;
    await settle(tester);
    click(first, NoteArt.closeRect.center);
    await settle(tester);
    expect(notes().notes, [second]);
    expect(stage.windows, isNot(contains(notes().actorOf(first))));
    click(second, const Offset(120, 60));
    expect(opened, 1);
    await settle(tester);
    expect(notes().notes, isEmpty);
    await done(tester);
  });

  testWidgets('an unpinned note leaves after a quarter of an hour; a pinned one stays', (tester) async {
    begin();
    final unpinned = notes().leave(NoteKind.stretch, NoteWords.stretch)!;
    final pinned = notes().leave(NoteKind.testsPassed, NoteWords.testsPassed(null))!..pinned = true;
    await settle(tester);
    now = now.add(StickyNotes.lasts);
    await tester.pump(StickyNotes.lasts);
    await settle(tester);
    expect(notes().notes, [pinned]);
    expect(notes().notes, isNot(contains(unpinned)));
    expect(notes().ticking, isFalse, reason: 'nothing left to wait for');
    await done(tester);
  });

  testWidgets('only when Mischief may: none over a full-screen app or in quiet hours; up ones hide and come back', (tester) async {
    begin();
    final note = notes().leave(NoteKind.stretch, NoteWords.stretch)!;
    await settle(tester);
    fullScreen = true;
    t.desktop.mischief.check();
    expect(notes().hidden, isTrue);
    expect(stage.showing, isEmpty);
    expect(notes().leave(NoteKind.testsPassed, NoteWords.testsPassed(null)), isNull);
    expect(stageOfMischief!.previewNote(), isNull, reason: 'not even a preview over a full-screen app');
    fullScreen = false;
    t.desktop.mischief.check();
    await settle(tester);
    expect(stage.showing.containsKey(notes().actorOf(note)), isTrue, reason: 'back');
    t.desktop.settings.quietHours = const QuietHours(enabled: true, startMinute: 14 * 60, endMinute: 16 * 60);
    expect(notes().leave(NoteKind.testsPassed, NoteWords.testsPassed(null)), isNull);
    expect(stageOfMischief!.previewNote(), isNotNull, reason: 'you asked for it in Settings');
    await done(tester);
  });

  testWidgets('nobody can see the screen: hidden, and no timer at all', (tester) async {
    begin();
    notes().leave(NoteKind.stretch, NoteWords.stretch);
    await settle(tester);
    expect(notes().ticking, isTrue, reason: 'the quarter of an hour');
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 900, displaysAsleep: true));
    expect(notes().hidden, isTrue);
    expect(notes().ticking, isFalse);
    expect(stage.showing, isEmpty);
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 0));
    await settle(tester);
    expect(stage.showing, isNotEmpty);
    await done(tester);
  });

  testWidgets('a stretch break after the best part of an hour at the PC; a five-minute break starts the count again', (tester) async {
    begin();
    for (var minute = 0; minute < 30; minute++) {
      t.desktop.world.tick();
      now = now.add(const Duration(minutes: 1));
      t.desktop.rhythm.report(SystemActivity(idleSeconds: minute.isEven ? 5 : 40));
      t.desktop.world.tick();
    }
    expect(stageOfMischief!.activeMinutes, greaterThan(20));
    t.desktop.rhythm.report(const SystemActivity(idleSeconds: 320));
    now = now.add(const Duration(minutes: 1));
    t.desktop.world.tick();
    expect(stageOfMischief!.activeMinutes, 0, reason: 'a real break');
    for (var minute = 0; minute < MischiefStage.stretchAfter + 1; minute++) {
      now = now.add(const Duration(minutes: 1));
      t.desktop.rhythm.report(const SystemActivity(idleSeconds: 3));
      t.desktop.world.tick();
    }
    expect(notes().notes.single.kind, NoteKind.stretch);
    expect(notes().notes.single.title, 'Stretch break?');
    expect(notes().notes.single.detail, 'I’ll keep an eye on your PC.');
    await done(tester);
  });

  testWidgets('its own switch off: no notes (the rest of Mischief carries on)', (tester) async {
    begin();
    t.desktop.settings.mischief = t.desktop.settings.mischief.withExtra(MischiefExtra.stickyNotes, false);
    expect(notes().leave(NoteKind.stretch, NoteWords.stretch), isNull);
    expect(t.desktop.mischief.may(MischiefExtra.celebrations), isTrue);
    await done(tester);
  });

  test('every note says your PC, never another device', () {
    for (final words in [
      NoteWords.testsPassed(null),
      NoteWords.testsPassed('web'),
      NoteWords.finishedAway(null),
      NoteWords.needsYouAway('web'),
      NoteWords.stretch,
      NoteWords.streak(7),
      NoteWords.hello,
    ]) {
      expect('${words.title} ${words.detail}', contains('your PC'));
      expect('${words.title} ${words.detail}', isNot(contains('Mac')));
    }
  });

  testWidgets('the picture: the note at 1× and 2×, its pin and × where the hit test says', (tester) async {
    final note = StickyNote(id: 1, kind: NoteKind.testsPassed, title: 'Claude finished the tests ✓', detail: 'All green on your PC.', created: now);
    for (final ratio in [1.0, 2.0]) {
      final image = NoteArt.image(note, ratio);
      expect(image.width, (StickyNotes.size.width * ratio).ceil());
      image.dispose();
    }
    expect(NoteArt.hit(NoteArt.closeRect.center.dx, NoteArt.closeRect.center.dy), 'close');
    expect(NoteArt.hit(NoteArt.pinRect.center.dx, NoteArt.pinRect.center.dy), 'pin');
    expect(NoteArt.hit(100, 60), isNull);
  });
}
