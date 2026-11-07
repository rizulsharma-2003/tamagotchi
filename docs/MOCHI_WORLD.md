# Mochi's world in Dart (`mochi_world`)

Sprint 2 **G1** and **G2**. `flutter/packages/mochi_world` is the Mac's pet-life engine (`Sources/TamagotchiCore`) in pure Dart, with no dependencies. Windows (W11–W18) and Android (A5) run it so that Mochi and Patch behave exactly as they do on the Mac. It isn't wired into `mochi_desktop` or `mochi_pocket` yet. This note says how to do that.

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

**Not ported**, because each one is its own Sprint 2 item or Windows already has its own:

- **`MenuBarRoamer` and the den.** Windows has its own taskbar walker. The world behaves as the Mac's does with no roam zone, which is the iPhone's case.
- **The adventure planner and scheduler (W19).** `setAdventureActive` is there.
- **`SpeechLines` (W11).** `say()` and the speech bubble are there.
- **The games (W14), the focus timer (W15), the daily recap (W16), seasons, and the room catalogue (W18).**
- **The event journal file and the connection-status UI.**
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

To regenerate the fixtures after a deliberate change on the Mac, run `MOCHI_WRITE_WORLD_FIXTURES=1 swift test --filter WorldFixture`, then `dart test` in `flutter/packages/mochi_world`.

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

## Windows (`mochi_desktop`, W11–W18)

What the app feeds in:

- **Claude's events.** Every `WireEvent` from the `BridgeServer` goes to `ingestWire(wire.toJson())`. Spooled events drained at launch are `delivery: EventDelivery.late`; after draining, call `noteSpoolDrained(delivered:, dropped:)`. Pings can go in too: they only update `lastPingAt`. Keep the bridge's own history if you want it (`onRecord` fires for every real event).
- **The PC's rhythm (W2).** `updateSystem(SystemActivity(idleSeconds:, displaysAsleep:, keepsDisplayAwake:, cpuLoad:))` every few seconds. With `followSystem` on, Mochi naps while the PC rests and wakes with a stretch when you're back.
- **Visibility.** `setWindowVisible(true)` while the main window or room is open (no badges then); `setSystemReducedMotion(...)` from Windows' "Show animations" setting.
- **Settings.** Assign `world.settings = ...` whenever Settings changes. `WorldSettings` uses the Mac's AppSettings keys, so the Windows settings JSON can hold them as they are.
- **Effects.** `play(SoundCue)` → the system player (W1 sounds). `postBanner` → Windows toasts (W1 already has the categories; the world only asks when the Mac would). `worldDidReact` and `userDidInteract` → W11 speech.

Per item:

- **W11 Mochi talks.** Call `say(text, speaker:)` from `worldDidReact`, `userDidInteract` and the sleepy and greeting moments, then draw `activeSpeech`. The curated lines (`SpeechLines`) and Haiku's fresh lines are still to port and build. Respect `settings.speechEnabled` and `chattiness`.
- **W12 grows up.** `LifeStage.stage(world.progress, DateTime.now())` gives kitten, young or grown-up when `settings.lifeStages` is on. `mochi_art` has the art. Celebrate the change once (the Mac keeps `lifeStageSeen`).
- **W13 Progress.** Use `world.progress`: hearts from `friendshipLevel` and `pointsToNextLevel`; achievements from `AchievementID.title`, `criteria` and `reward`. `world.toast` already announces unlocks.
- **W14 mini-games.** `RPSChoice` and `InteractionLibrary.rpsChoices` are here. `CatchGame` and `RPSGame` (Features) still need porting. Use `playPet` and `playCompanion` for reactions.
- **W15 Focus buddy.** `updateFocus(FocusStatus(phase:, petNaps:))`. Mochi naps, and non-urgent sounds stay quiet during focus.
- **W16 Daily recap.** Count from the events `onRecord` gives you (sessions, turns, tool calls, test runs, errors). `DailyRecap` still needs porting.
- **W17 Share a clip.** Render `world.frame(t)` for t over 5 s with `mochi_art`'s painters. It's deterministic, so it needs no screen capture.
- **W18 Room makeover.** Unlocks come from `Accessory.isAvailable(unlocked: progress.unlockedIDs, date:)` and the friendship level. The furniture catalogue lives in `mochi_art`'s `RoomLayout`.
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
