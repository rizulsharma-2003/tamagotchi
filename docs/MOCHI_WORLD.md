# Mochi's world in Dart (`mochi_world`)

Sprint 2 **G1** and **G2**, and the logic of **W11, W12, W14, W15, W16, W18 and W20**. `flutter/packages/mochi_world` is the Mac's pet-life engine (`Sources/TamagotchiCore`) in pure Dart, with no dependencies. Windows (W11–W20) and Android (A5) run it so that Mochi and Patch behave exactly as they do on the Mac. It isn't wired into `mochi_desktop` or `mochi_pocket` yet. This note says how to do that.

## What's in it

| Mac (TamagotchiCore) | Dart |
|---|---|
| `CompanionWorld` (+ Speech, Focus, Adventure) | `MochiWorld` (without the menu-bar roamer; see below) |
| `CharacterAnimator`, `CharacterAnimations` | `CharacterAnimator`, `PetAnimation` (39 states including `scripted`), `CompanionAnimation` (35) |
| `PetPoseEvaluator`, `PetIdleLife`, `PetSecondaryMotion` (follow-through), `PetChoreography`, `PetPlay`/`PetTreat`/`PetAffection` (every variant) | the same names, in `lib/src/animation/` |
| `CompanionPoseEvaluator` | `CompanionPoseEvaluator` |
| `InteractionLibrary` (16 scripts, frames, props), `InteractionScheduler`, `SplitMix64` | the same |
| `EventNormalizer`, `CompanionEvent`, `SessionRegistry` | the same (the normalizer reads a wire event's JSON) |
| `EventToAnimationMapper`, `NotificationPolicy`, `BannerCoalescer` | the same |
| `AchievementEngine`, `ProgressState`, `Accessory` unlocks, `LifeStage` | the same (progress JSON uses the Mac's `progress.json` keys) |
| (new, G2) | `Celebrations`: the strict "really happened, just now" classifier |
| `SpeechLines`, `SpeechOccasion`, `SpeechPacing`; the rules of the App's `SpeechController` | the same, and `SpeechDirector` (W11) |
| `CatchGame`, `RPSGame`, `GameModels`; the rules of the App's `GamesController` and `RPSGameView` | `CatchGame`, `RPSMatch`/`RPSRound`/`RPSTally`, `GameRecords`, `RPSStage` (W14) |
| `FocusTimer`, `FocusModels`, `FocusLog`; the rules of the App's `FocusController` | the same (the log without its file), and `FocusBuddy` (W15) |
| `DailyRecap`, `RecapSettings`, `EventJournal`'s retention; the rules of the App's `RecapController` and card | the same (the journal without its file), and `RecapSchedule` (W16) |
| `FurnitureCatalog`, `RoomModels`; the room editor's rules | `FurnitureCatalog`, `RoomLayout`, `PlacedFurniture` (W18) |
| `SeasonModels`; the rules of the App's `SeasonDecor`, `SeasonalTreats` and `SeasonController` | `SeasonCalendar`, `SeasonDecor`, `TreatStyle`, `SeasonTracker` (W20) |
| The App's `GrowthController` | `Growth.check` (W12) |

**Not ported**, because each one is its own Sprint 2 item, is drawing, or Windows already has its own:

- **`MenuBarRoamer` and the den (W22).** Windows has its own taskbar walker. The world behaves as the Mac's does with no roam zone, which is the iPhone's case.
- **The adventure planner and scheduler (W19).** `setAdventureActive` is there.
- **Files and models.** The focus log, the event journal and the greeted holidays have `toJson` and `load`; the host stores them. Fresh speech lines come in through a hook (see W11 below).
- **Drawing.** The game fields, the recap card and its image, the room's scene geometry (`RoomSpace`, in `mochi_art`) and the holiday art. Times and dates in the user's locale are the host's too: the API takes a `formatTime` or `formatDay` callback where the Mac's text has one.
- **The connection-status UI.**
- **`ListeningPose` and `PetTinyFit`.** `mochi_art` already has these.

## Parity with the Mac

The Mac is the specification, and golden fixtures check it. `Tests/TamagotchiCoreTests/WorldFixture*.swift` runs the Swift engine with fixed seeds and a scripted clock and writes `link-spec/world/*.json`. The Dart tests replay the same inputs and must match. The Swift test also requires the committed fixtures to equal what the engine produces now, so the two can't drift apart.

| Fixture | What it covers |
|---|---|
| `poses-pet.json` | Every pet animation and variant over time, including:<br>• Reduced Motion, calm and lively<br>• one-shots settling onto `watch`/`sleep`/`waveGently`/`sit`<br>• short and long slots<br>• a seed above 2^63<br>• variants picked from the start time<br>• minutes of idle, sleep and watch |
| `poses-companion.json` | Every companion animation, with the waiting bubbles. |
| `interactions.json` | All 16 scripts: their beats and whole frames (both poses and the props), plus the rock-paper-scissors hands, Reduced Motion and lively. |
| `scheduler.json` | 14,200 scheduler steps over idle days with work, busy, waiting, absent, asleep, paused, lively, calm and Reduced Motion stretches. Shows that cooldowns, daily caps, no-repeat and the variants are the same. |
| `progress.json` | Petting, play and treats past their daily caps; levels; every achievement; simulated and late events not counting; life stages and their "next step" text. |
| `celebrations.json` | 17 Claude timelines (G2), each with the session transition, the reaction, the notification decision and the strict celebration. Also 40 shell commands through `CommandClassifier`, which `mochi_wire`'s test checks too. |
| `world.json` | 5 whole `CompanionWorld` timelines with 165 snapshots. Each snapshot records the animator states and tokens, the interaction, mood, badge, caption, toast, progress, the sounds, banners and callbacks the world sent, and the frame (both poses and the props). |
| `speech.json` (W11) | Every occasion's lines, importance and situation, with 24 seeded picks each; pacing for every chattiness, occasion and gap; greetings by hour; 23 generated lines cleaned up (with Swift's character counts, emoji included); the occasion for 22 kinds of Claude event. |
| `games.json` (W14) | The difficulty tables; 5 whole games of Catch the Treats with every event, the whole state at checkpoints and Mochi's pose along the way:<br>• autopilot at 60 fps, and at 10 fps up to the top level<br>• keys with uneven frames<br>• dragging<br>• treats placed by hand<br>Also 4 rock-paper-scissors matches of 60 rounds, and the records. |
| `focus.json` (W15) | Durations from settings; the clock text; 6 timer scenarios (on time, late, slept through, skips, restarts, one cycle per set); the focus log's retention. |
| `recap.json` (W16) | 14 recaps of scripted days, with tiles, summary and banner. They include simulated, unknown and late events, other days' events, partial and missing history, streaks and ties. Also the 18:00 rule, day names and day keys. |
| `room.json` (W18) | The catalogue; what 6 progress states unlock; snapping (non-finite input too); one room arranged in 20 steps (free spots, moves, flips, the size limit, drawing order); a newer version's room cleaned up; the Mac's JSON. |
| `seasons.json` (W20) | Every day from 2025 to 2030 for 5 settings (birthdays, a leap day, an impossible date, Mochi's adoption day, decorations off): the event shown and any overlaps. For sample days: the next event, the last day of a run and the occasion key. |

To regenerate the fixtures after a deliberate change on the Mac, run `MOCHI_WRITE_WORLD_FIXTURES=1 swift test --filter WorldFixture`, then `dart test` in `flutter/packages/mochi_world`. The feature fixtures come from `Tests/TamagotchiCoreTests/WorldFixtureFeatures.swift`.

The fixtures only reach TamagotchiCore. Some feature rules live in the Mac's App target, which Swift tests can't call: when Mochi speaks, the focus and recap toasts and lines, the game sounds and stage, the holiday greetings and costumes, and growing up. Those are ported line by line and covered by Dart-only tests.

Where Swift's behaviour depended on something Dart does differently, the port reproduces it exactly:

- SplitMix64 and `Ease.hash` use 64-bit wrapping arithmetic on the Dart VM. UInt64 values are carried as their bit patterns; `unsignedMod` and `unsignedString` handle the unsigned parts.
- Swift's IEEE `remainder` is `ieeeRemainder`.
- Swift's `Int %` becomes `.remainder`.

Swift's dictionary order is random. The fixtures avoid ties that would depend on it. Dart keeps insertion order.

## The API in a few lines

```dart
final world = MochiWorld(
  settings: WorldSettings.fromJson(saved['settings']),   // the Mac's AppSettings keys
  achievements: AchievementEngine(state: ProgressState.fromJson(saved['progress']), onChange: saveProgress),
  seed: installSeed,                                    // a UInt64 bit pattern; keep one per install
  effects: myEffects,                                   // sounds, banners, worldDidReact, userDidInteract
);
world.restore(savedWorld, progressToo: false);          // sessions from the last hours, no reactions

Timer.periodic(const Duration(milliseconds: 250), (_) => world.tick());   // 4 Hz, like the Mac and the iPhone
bridge.onEvent = (wire) => world.ingestWire(wire.toJson());              // mochi_wire WireEvent
world.interact(PetInteraction.play);                                      // the Pet / Play / Treat buttons

// Every display frame:
final f = world.frame();   // f.pet, f.companion (poses), f.props, f.companionVisible
world.activeSpeech; world.activeCaption; world.activeToast; world.status.mood; world.progress;
```

`MochiWorld(clock:, uptime:, calendar:)` takes the wall clock, a monotonic clock and local time from outside; tests pass fixed ones. `frame(time)` can be evaluated at any time, so a clip can be rendered off-screen (W17).

The pieces also work on their own:

- `PetPoseEvaluator.pose(animation, elapsed:, duration:, context:, variant:)` and `CompanionPoseEvaluator.pose(...)`
- `InteractionLibrary.frame(...)` and `InteractionScheduler`
- `LifeStage.stage(progress, now)` and `LifeStage.nextStep(...)`
- `Celebrations().observe(event)`

## The features (W11–W20)

Each feature is plain state plus the Mac's rules, deterministic for a seed and the clock you pass. Where the Mac's controller would show something, the Dart API returns a `FeatureMoment`: a toast, a speech line, a Mochi and a Patch animation, a sound and a banner, each optional. `moment.applyTo(world)` performs it with the Mac's rules:

- sounds only with sound on, and outside quiet mode or quiet hours;
- banners only when the user asked for that feature's banners, and never while paused or quiet.

The settings classes read and write the Mac's AppSettings keys (`focus`, `games`, `recap`, `room`, `seasonal`, `lifeStageSeen`), so the Windows settings file can hold them as they are.

```dart
// W11 speech: wire it to the world's effects and tick it with the world.
final speech = SpeechDirector(world, writer: haikuLines);      // the writer is optional; see W11 below
// in your WorldEffects: worldDidReact → speech.react(event, session), userDidInteract → speech.interacted(kind)
speech.windowVisible = mainWindowOpen;
speech.tick();                                                    // with world.tick(), at 4 Hz

// W14 Catch the Treats: step it every frame, then draw its state.
final game = CatchGame(seed);
for (final e in game.step(dt, CatchInput(direction: keys, targetX: dragX))) {
  CatchGame.momentFor(e)?.applyTo(world);
  if (e is CatchGameOver) game.finish(records, petName: name).$2.applyTo(world);   // records: GameRecords
}

// W14 rock-paper-scissors: picks before the shake, scored at RPSStage.shake.
final match = RPSMatch(seed, withCompanion: patchShows);
final picks = match.nextPicks();
final round = match.play(RPSRound(player: choice, pet: picks.pet, companion: picks.companion));
RPSMatch.reveal(round, streak: match.streak, records: records).applyTo(world);

// W15 focus.
final focus = FocusBuddy(world, settings: FocusSettings.fromJson(saved['focus']), log: focusLog, computer: 'PC');
focus.toggle();
focus.tick();                                                     // with world.tick()

// W16 recap: keep the journal from onRecord; check the schedule every minute.
final journal = EventJournal(retentionDays: historyDays);       // MochiWorld(onRecord: (e) => journal.append(e, now: DateTime.now()))
DailyRecap today() => DailyRecap.compute(
  day: DateTime.now(), events: journal.all, focus: focusLog.blocks,
  historyStart: journal.historyStart(now: DateTime.now(), launchedAt: launchedAt));
RecapSchedule.check(now: DateTime.now(), settings: recapSettings, recapFor: today, world: world.settings,
    where: 'Open Recap from the tray.')?.applyTo(world);        // save recapSettings when it returns a moment

// W18 room, W20 holidays, W12 growing up.
final room = RoomLayout.fromJson(saved['room']);
room.addUnlocked(kind, world.progress);
final seasons = SeasonTracker.fromJson(savedSeasons);
seasons.refresh(DateTime.now(), settings: seasonal, adopted: world.progress.firstMetAt, petName: name, companionName: patch)
    ?.applyTo(world);
final growth = Growth.check(world.progress, DateTime.now(), lifeStages: world.settings.lifeStages, seen: lifeStageSeen, petName: name);
```

`mochi_art` has some of the same names: `SeasonalEvent`, `TreatStyle`, `Wearer`, `FurnitureKind`, `FurnitureCatalog`, `PlacedFurniture`, `RoomLayout` and `FurniturePlacement`. They have the same values and JSON. Import one of the two packages with a prefix, as for the poses; `art.RoomLayout.fromJson(room.toJson())` hands a room to the painters.

## Celebrations (G2)

The world already celebrates exactly as the Mac does: a high five, a victory dance, the trophy, detective mode, case closed, graduation or the synchronized dance.

`Celebrations` is the same decision, made for hosts that only want the answer. Each `Celebration` carries:

- a `reason`: turn finished, long turn, build/test passed, investigating, case closed, first milestone, milestone, or commit
- the interaction
- the Mac's full `Reaction`, including its caption and banner text

It answers only for live, real events, never for simulated, late or restored ones. Feed it every event in order, because it keeps its own session state. Uses: X10 full-screen confetti, X9 sticky notes, a toast, the Windows taskbar pet.

Like the Mac, the world itself still animates simulated activity (the simulator, or a phone mirroring the computer), but never counts it towards progress, never posts banners for it, and never stores it.

Two rules decide a long turn and a real result:

- A turn is only "long" (`longTurnMinutes`, 10 by default) when both its prompt and its `Stop` arrived live.
- A build or test only counts when it's an explicit report, or when `mochi_wire` recognised a build/test command (`commandKind`) whose exit status is trustworthy (`commandReliable`: not piped, not backgrounded, not followed by `;`). The hook helper already sends both fields on Windows.

## Windows (`mochi_desktop`, W11–W20)

What the app feeds in:

- **Claude's events.** Every `WireEvent` from the `BridgeServer` goes to `ingestWire(wire.toJson())`. Spooled events drained at launch are `delivery: EventDelivery.late`; after draining, call `noteSpoolDrained(delivered:, dropped:)`. Pings can go in too: they only update `lastPingAt`. Keep the bridge's own history if you want it (`onRecord` fires for every real event).
- **The PC's rhythm (W2).** `updateSystem(SystemActivity(idleSeconds:, displaysAsleep:, keepsDisplayAwake:, cpuLoad:))` every few seconds. With `followSystem` on, Mochi naps while the PC rests and wakes with a stretch when you're back.
- **Visibility.** `setWindowVisible(true)` while the main window or room is open (no badges then); `setSystemReducedMotion(...)` from Windows' "Show animations" setting.
- **Settings.** Assign `world.settings = ...` whenever Settings changes. `WorldSettings` uses the Mac's AppSettings keys, so the Windows settings JSON can hold them as they are.
- **Effects.** `play(SoundCue)` → the system player (W1 sounds). `postBanner` → Windows toasts (W1 already has the categories; the world only asks when the Mac would). `worldDidReact` and `userDidInteract` → `SpeechDirector` (W11).

Per item:

- **W11 Mochi talks.** `SpeechDirector` decides when Mochi or Patch speaks, as the Mac's SpeechController does, and puts the line in the world; draw `world.activeSpeech` over the speaker.
  - Feed it the world's `worldDidReact` and `userDidInteract`, set `windowVisible` while Mochi's window is open (greetings wait for it), and call `tick()` with the world's. It follows `speechEnabled`, `chattiness` and `pauseReactions`.
  - **Fresh lines.** Give it a `writer`. For each occasion it's asked about, run `FreshLinePrompt(occasion, petName:, companionName:, home: 'the Windows taskbar')` through Claude Haiku (`claude -p`, with `instructions` as the system prompt and `prompt` as the request), and keep what `SpeechLines.sanitize` returns. The director asks every two hours while `speechFreshLines` is on, keeps three lines per occasion and uses one about half the time. Only the kind of moment is sent, never anything about the work.
  - Settings › Speech: the Mac's "Apple Intelligence" switch becomes "Fresh lines from Claude Haiku", stored under the Mac's key `speech.useAppleIntelligence`.
- **W12 grows up.** Call `Growth.check(world.progress, now, lifeStages:, seen:, petName:)` every minute. Draw its `stage` (`mochi_art` has the art), store `seen` as `lifeStageSeen` when it changes, and apply its `moment` ("Meet kitten Mochi!" at first, then "Mochi grew up!" once per stage).
- **W13 Progress.** Use `world.progress`: hearts from `friendshipLevel` and `pointsToNextLevel`; achievements from `AchievementID.title`, `criteria` and `reward`. `world.toast` already announces unlocks.
- **W14 mini-games.**
  - *Catch the Treats.* Make a `CatchGame(seed)` per game and step it every frame with `CatchInput(direction:)` for ←/→ or A/D, or `targetX:` while dragging (field units, 0…1). Pause by not stepping. Draw `treats` (with `rotation`), `splashes` (fading over `splashLife`; `points > 0` is a "+n" label), the score, `combo` (with `multiplier(combo)` from 2 in a row), the lives (`maxMisses - misses`), "Faster!" after a `CatchFaster`, and Mochi with `petPose(context)` at `petX`. Apply `CatchGame.momentFor(event)` for each event and `finish(records, petName:)` on `CatchGameOver`. Keep `GameRecords` under the Mac's `games` key.
  - *Rock-paper-scissors.* Make an `RPSMatch(seed, withCompanion: companionVisibility != never)`. On a pick (`rpsChoiceForKey` for R/P/S and 1/2/3), take `nextPicks()` and show `RPSStage.chant` with `RPSStage.petPose` and `companionPose(round, elapsed, context)`. At `RPSStage.shake`, score it with `match.play(round)` and `RPSMatch.reveal(...)`, then show `round.result(...)` and `RPSStage.badge`. Take the next pick after `RPSStage.roundLength`.
- **W15 Focus buddy.** Make a `FocusBuddy(world, settings:, log:, computer: 'PC')`; call `toggle()`, `skip()` and, with the world's, `tick()`. It tells the world when Mochi naps (`world.focus`), logs completed blocks, and shows each transition as the Mac does: the lines and toasts, the wake–stretch–play break, and the chime and banner if they're on. Draw the timer from `world.focus` (`remaining`, `progress`, `cycle`, `phase.title`, `focusClock`). Save `log.toJson()` when a block completes (unless `log.persists` is false), and `FocusSettings` under `focus`.
- **W16 Daily recap.** Keep an `EventJournal` (its retention is the history setting), fed from `MochiWorld(onRecord:)` and saved as JSON lines.
  - `DailyRecap.compute(...)` gives the card: `title`, `streakText`, `tiles` (each with `value`, `label` and `detail`; format `RecapActiveSpan`'s times yourself), `summary`, `quietMessage` and `footer`.
  - Run `RecapSchedule.check(...)` every minute and 8 s after launch. Save `RecapSettings` (the `recap` key) when it announces.
  - Saving or copying the card as an image is drawing, still to do.
- **W17 Share a clip.** Render `world.frame(t)` for t over 5 s with `mochi_art`'s painters. It's deterministic, so it needs no screen capture.
- **W18 Room makeover.** `RoomLayout` (the Mac's `room` key) holds the placed pieces.
  - The Decorate tray lists `FurnitureCatalog.all`, with `isUnlocked(world.progress)` and `unlockHint`.
  - A drop calls `room.drop(kind, existing:, overTray:, x:, y:, progress:)`. Positions are normalized; `mochi_art`'s `RoomSpace` maps them to the scene. Flip and remove by id, and draw in `drawingOrder`.
  - Settings › Room shows `room.summary(progress)`.
- **W20 Holidays.**
  - Call `SeasonTracker.refresh(now, settings:, adopted: world.progress.firstMetAt, ...)` at launch (with `greet: false`, then again a few seconds later), on the hour, at midnight, on wake, and when the seasonal settings change.
  - Its `event` picks the decorations (`mochi_art` draws them in the room and on the taskbar strip), the costume (`SeasonDecor.costume`, worn unless the user chose an accessory), the treat (`TreatStyle.of`) and the birthday candles.
  - Apply the greeting it returns (once per occasion). Show `takePendingToast(windowVisible:)` when the window opens, and save `toJson(now:)`, the Mac's `seasons.json`.
  - Settings › Holidays uses `SeasonCalendar.statusLine` and `SeasonalSettings` (the `seasonal` key).
- **Taskbar roaming.** The world has no roamer. Windows' taskbar walker keeps moving Mochi, but should stop wandering while the world is reacting. On the Mac, the roamer freezes when either of these holds:
  - `world.interaction != null`
  - a one-shot of priority ≥ `reaction` is playing (`world.pet.isPlayingOneShot && world.pet.current.priority >= AnimationPriority.reaction`)

  Draw the world's pose (`frame().pet`) at the walker's position. Scripts move Mochi along the path towards Patch; `x` is in path units, 0 at Mochi's spot and 1 at Patch's. With Patch on the taskbar, map that path between the two characters' positions.
- **W26/N1.** The engine is UI-free, so a second window or a native stage only needs the poses.

## Android (`mochi_pocket`, A5)

Run one `MochiWorld` for the room, as the iPhone runs `CompanionWorld` (`iOS/MochiPocket/PhoneWorld.swift`):

- Construct it with `companionVisibility: always` (Patch keeps Mochi company all the time).
- **Follow the computer.** Turn the room's Claude state (`claude`: phase and category) into **simulated** wire events, exactly as `PhoneWorld.play` does:
  - a mirror session: `SessionStart`, `UserPromptSubmit`, `PreToolUse`/`PostToolUse` with the category's tool, `Notification` with `permission_prompt` for waiting, `Stop`, `StopFailure` and `SessionEnd`
  - `origin: 'simulator'`

  Mochi then reacts on the phone, but the phone never counts progress twice: the computer is the one that counts. The `resting` flag becomes `updateSystem(SystemActivity(idleSeconds: resting ? 86400 : 0))`.
- **Petting, play and treats.** Both ways, as on the iPhone. Call `world.interact(kind)` for the phone's own buttons and send `phoneInteraction`; for the computer's `macInteraction` (within 90 s, not seen before), call `world.interact(kind)`.
- **The look.** Name, colours and room come from the room's `look`. Show the friendship level from the look too: the computer's progress is the real one.
- Tick at 4 Hz while the room is visible; pause the timer in the background.

## Persistence

- **Progress.** Write `ProgressState.toJson()` from `AchievementEngine.onChange`, as the Mac writes `progress.json`: the same keys, with ISO dates. `ProgressState.fromJson` reads the Mac's file too.
- **History.** `world.toJson()` keeps the progress and up to 3 hours of real events (at most 4,000). `world.restore(json)` rebuilds Claude's sessions from them without reacting, as the Mac's `restoreFromJournal` does.
  - Store it on quit and every few minutes, in `%LOCALAPPDATA%\Mochi` beside the app's other state on Windows, or the app's files directory on Android.
  - Paths are never stored. Project keys are already hashes.
- **Features.** Store the settings groups under the Mac's keys (`focus`, `games`, `recap`, `room`, `seasonal`, `lifeStageSeen`, `speech`). Also store the focus log (`FocusLog.toJson`), the recap's event journal (`EventJournal.toJsonLines`, a week by default) and the greeted holidays (`SeasonTracker.toJson`). With history off (0 days), the focus log and the journal stay in memory.
- **Not stored.** Animation and scheduler state (`CharacterAnimator` and `InteractionScheduler` have `toJson` if ever needed). Like the Mac, a new launch starts calm.
- **Seed.** Keep one per install, so Mochi's habits feel like its own; any non-zero 64-bit value works.

## Performance

Measured with the Dart VM in JIT mode on an Apple-silicon Mac:

| Operation | Cost |
|---|---|
| `tick()` | ~3 µs |
| `frame()` at idle | ~10 µs |
| `frame()` in the busiest clips (play, treats: secondary motion re-samples the pose 12–16 times) | ~50 µs |

At 30 fps that is well under 1% of one core, even ×10 on the ARM VM under x64 emulation; the paint costs more. Things to keep in mind:

- Call `frame()` once per painted frame and share it between Mochi and Patch.
- Tick at 4 Hz, as the Mac and the iPhone do; there's no need for more, because poses are pure functions of time and stay smooth at any frame rate.
- Pause ticking and painting when nothing is visible (the taskbar is hidden, a full-screen game is running).

The engine needs 64-bit integers, so it runs on Windows, Android and the Dart VM, but not on the web.

## Rendering with `mochi_art`

`mochi_world` has its own copy of the pose model. `PetPose`, `CompanionPose`, `Effect`, `SceneProp` and the animation enums have the same names, fields and JSON as `mochi_art`'s, so `mochi_art`, which depends on Flutter, could stay untouched while other work was going on. Until the two are merged, convert at the boundary:

```dart
import 'package:mochi_art/mochi_art.dart' as art;
import 'package:mochi_world/mochi_world.dart' as world;

art.PetPose.fromJson(frame.pet.toJson());   // likewise CompanionPose and SceneProp
```

That costs a few microseconds per frame. A follow-up removes it: make `mochi_art` depend on `mochi_world`, and replace its `model/poses.dart`, `ease.dart` and the animation, interaction and accessory enums in `model/world.dart` with re-exports. The APIs are a superset of `mochi_art`'s, with `copy()` no longer going through JSON. Do it once the apps aren't being edited in parallel.
