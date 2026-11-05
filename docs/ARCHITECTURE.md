# Architecture

Four Swift package targets keep the testable logic away from UI:

| Target | Role |
|---|---|
| `TamagotchiWire` | Foundation-only: `WireEvent` envelope, `HookPayloadSanitizer`, `CommandClassifier`, `ToolCategoryClassifier`, `BridgeClient` (socket client), `EventSpool`, `BridgePaths`. Shared by the helper and the app. |
| `mactamagotchi-hook` | The hook command. `claude-hook`, `report`, `ping`. |
| `TamagotchiCore` | Everything testable without UI (below). |
| `MacTamagotchi` | AppKit/SwiftUI app: status item, popover, renderers, desktop pet, windows, services, dev tools. |

## Core modules (TamagotchiCore)

| Brief module | Implementation |
|---|---|
| LocalEventBridge | `Bridge/LocalEventBridge.swift` — Unix socket server, peer UID check, bounds, timeouts, health check |
| EventSchemaValidator | `Events/EventSchemaValidator.swift` |
| EventNormalizer | `Events/EventNormalizer.swift` → `CompanionEvent` (id, kind, timestamps, session, project, tool, metadata, origin, delivery, schema version, confidence, summary) |
| SessionRegistry | `Sessions/SessionRegistry.swift` — per-session state machine and the primary-session rule |
| EventToAnimationMapper | `Mapping/EventToAnimationMapper.swift` — pure: event + session → `Reaction` |
| CharacterAnimationEngine | `Animation/CharacterAnimator.swift` — priorities, interrupts, cooldowns, completion tokens, cancellation |
| PetCharacter / ClaudeCharacter | `Animation/PetPoseEvaluator.swift`, `Animation/CompanionPoseEvaluator.swift` — pure pose functions |
| CharacterInteractionEngine | `Interactions/InteractionLibrary.swift` (scripts) + `InteractionScheduler.swift` (seeded, weighted, cooldowns, daily caps) |
| EventJournal | `Storage/EventJournal.swift` — JSONL, retention, path stripping, refuses simulated events |
| SettingsStore | `Settings/` — tolerant decoding, quiet hours |
| NotificationCoordinator (policy) | `Notifications/NotificationPolicy.swift` — per-category decisions, banner coalescing |
| AchievementEngine | `Progress/` — achievements, friendship, accessories |
| ClaudeHookInstaller | `Integration/ClaudeHookInstaller.swift` + `OrderedJSON.swift` (order-preserving JSON) |
| ClaudeCodeIntegration | `Integration/ClaudeCodeLocator.swift`, `ClaudeHookEvent.swift`, `HookCompatibility` |
| Providers | `Bridge/EventProviders.swift` — `EventProvider` protocol; `ClaudeHookEventProvider` |
| Simulator | `Simulator/EventSimulator.swift` |
| Menu-bar roaming | `Roaming/` — `MenuBarRoamer` (seeded, continuous segment plans evaluated purely by time: rests, wander, sniff, zoomies, ball/yarn/butterfly/leaf play, naps, bed), `RoamGeometry` (zone, notch, occupied icons, clock guard), `PoseSignature` (frame-skip signatures) |
| Pet animation families | `Animation/PetIdleLife`, `PetPlayAnimations`, `PetTreatAnimations`, `PetAffectionAnimations`, `PetChoreography`, `PetSecondaryMotion` (follow-through by re-sampling the pose over the last 0.4 s), `PetTinyFit` (menu-bar fit) |
| World | `World/CompanionWorld.swift` — the orchestrator; feature state (`adventureActive`, `focus`, `speech`) is changed through `CompanionWorld+Adventure/Focus/Speech.swift` |
| Speech | `Features/SpeechLines.swift` — occasions, hand-written lines, chattiness pacing, sanitizing generated lines |
| Growing up | `Features/LifeStage.swift` — kitten / young / grown-up from friendship and time together (monotonic) |
| Desktop adventures | `Adventure/AdventureTerrain.swift` (window tops, Dock, floor), `AdventurePlanner.swift` (seeded, time-sampled routes; re-plans when windows move), `AdventureScheduler.swift` (spontaneous adventures) |
| Notch den | `Roaming/MenuBarRoamer+Den.swift` — den naps, peeks and bursts; `RoamGeometry` finds the den at the notch edge |
| Mini-games | `Features/CatchGame.swift` (seeded step function), `Features/RPSGame.swift` |
| Focus buddy | `Features/FocusTimer.swift` (phase machine), `Features/FocusLog.swift` |
| Daily recap | `Features/DailyRecap.swift` — the day's numbers from real journal events and the focus log |
| Holidays and room | `Features/SeasonModels.swift` (`SeasonCalendar`), `Features/RoomModels.swift`, `Features/FurnitureCatalog.swift` |
| iPhone Live Activity | `Phone/LiveActivityModels.swift` — `PhoneSettings`, `LiveActivityPlanner` (sessions → phase), `LiveActivityPayload` (APNs start/update/end, which the relay pushes) |
| Mochi Link | `Link/` — `LinkKey` and `LinkStore` (`RelayLinkStore` when paired, `LocalLinkStore` when not; `MochiLink.use`), `LinkCrypto` (AES-GCM, test vectors in `link-spec/`), `LinkPush` (sealed alerts and Live Activities), `LinkCredentials` + `LinkPairing` (Keychain, QR pairing). See MOCHI_LINK_PLAN.md |
| Ask Mochi | `Assistant/QuickCommands.swift` (instant, deterministic commands), `AssistantBrain.swift` (`BrainLaunch` flags and instructions, `BrainContext`, `BrainEvent` stream parsing, `BrainStep`, `AgentNames` session-name ↔ project matching), `MCPServerCore.swift` + `AnyJSON.swift` (the tools protocol), `AssistantSettings.swift` |

App: `AppEnvironment` (composition root), `MenuBar/` (StatusItemController, MenuBarOverlayController — the click-through overlay over the menu bar, accepting the mouse only over Mochi — MenuBarPetCanvas, MenuBarStageView, MenuBarDen, MenuBarGlyph for the classic icon),
`Features/` (one folder per feature: Adventure, Assistant, Phone, Focus, Games, Growth, Recap, Room, Seasons, Share, Speech, Widget — each a controller created lazily by `AppEnvironment` plus its views and art),
`Popover/`, `Rendering/` (Scene, Pet, Companion, Items/Effects, Accessories, Themes), `Desktop/`,
`Windows/` (Settings, Activity, Welcome), `Services/` (sound, notifications, hot key, login item,
reduced motion), `Integration/` (IntegrationController, headless commands), `Dev/` (snapshots, debug hooks).

## Event pipeline

```
provider (bridge queue) ─▶ main actor: CompanionWorld.ingest
   normalize ─▶ dedupe (recent ids + journal) ─▶ SessionRegistry.apply ─▶ journal (real only)
   ─▶ achievements (live, real only) ─▶ presence ─▶ mapper ─▶ NotificationPolicy.decide
   ─▶ animators / interaction / caption / badge / sound / banner ─▶ base loops from the primary session
```

`CompanionWorld` is `@MainActor @Observable`. The bridge validates on its own queue and hops to the main
actor with already-validated `Sendable` values. A 4 Hz tick advances animators, ends interactions,
schedules ambient behaviour, handles naps, presence and pruning; mutations happen only when state
actually changes, so idle ticks don't invalidate views.

## Animation system

- **Animator** (`CharacterAnimator<A>`): always exactly one thing playing — the base loop or a one-shot.
  A request replaces the current one-shot only at equal or higher priority (`ambient < interaction <
  reaction < user < attention < critical`); lower requests are dropped, never queued, so stale reactions
  can't pile up. One-shots end into the base loop *as it is then*, so characters never get stuck. Each start
  returns a token; completions and cancellations carry it, so obsolete callbacks are ignored.
- **Poses** are pure functions of (animation, elapsed time, global time, seed, reduced motion, intensity).
  Breathing and blinking continue across animations. Reduced motion zeroes translation, rotation and squash
  and keeps expressions; walking interactions happen in place.
- **Interactions** are timelines of beats for both characters plus scene props. Both animators run a
  `scripted` one-shot with the same id; if anything interrupts either side, the other is cancelled cleanly.
  Scripts must end where they started (tested), so nothing snaps afterwards.
- **Scheduler**: SplitMix64-seeded, global gap (150 s × intensity), per-interaction cooldowns and daily
  caps, no repeats of the last two, context rules (idle/working; never while Claude waits for you),
  postponed after real events.

## Rendering

Procedural vector art in a single `Canvas` per scene (`SceneRenderer`). The companion is pixel art
(`PixelMascot`): cells per pose for eyes, arms, legs and hats, filled as one path per colour so edges never
seam, with smooth translation and squash on top. The scene's `TimelineView` closure must read `timeline.date`
— SwiftUI skips redrawing a `Canvas` whose inputs are unchanged, which is what once made the popover choppy.
The popover runs at 60 fps while open. SwiftUI reads world state once
per state change into a `SceneSnapshot`; a `TimelineView` drives frames only while the hosting window is
actually visible (`WindowVisibilityReader`), at 30 fps during action and 15–20 fps when calm (12 fps with
reduced motion). Glows use radial gradients instead of blur filters. The menu bar uses a separate
CoreGraphics template glyph with an adaptive one-shot timer (blinks, a 0.8 s antenna pulse while working,
a short celebration hop), so an idle menu bar costs nothing.

Measured on an M-series Mac (release build): idle in the menu bar ≈ 0.2 % CPU; working session ≈ 2 %;
popover open ≈ 1.6 %; desktop pet visible ≈ 5 % of one core; hook latency median 4.4 ms.

## The desktop widget

`Widget/MacTamagotchiWidgets.swift` is compiled by `scripts/build-app.sh` into
`Contents/PlugIns/MacTamagotchiWidgets.appex` (SwiftPM can't build app extensions). It is sandboxed with a
read-only exception for `~/Library/Application Support/MacTamagotchi/Widget/`, where `WidgetPublisher` writes
`status.json` and a scene picture when the status changes and asks WidgetKit to reload (at most once a minute).

## Ask Mochi

```
⌥Space (tap: type · hold: talk) ─▶ AssistantController ─▶ QuickCommands ─▶ MacActions (done on the Mac)
                                            │ anything else
                                            ▼
                        BrainSession: claude -p --name mochi --input-format stream-json …
                          │ tools: mcp__mochi__* (+ approve)          │ ListAgents / SendMessage
                          ▼                                            ▼
          mactamagotchi-hook paws ─▶ PawsServer (0600 socket + token)   Claude Code session messaging
                                     → MacActions / approval card        → "Message from @mochi" in that session
```

- The helper session is started on demand, kept for follow-ups and stopped after 10 quiet minutes. It runs
  with `--setting-sources project` in its own empty folder, `--strict-mcp-config`, `--tools
  ListAgents,SendMessage,WebSearch`, `--no-session-persistence`, and a settings layer that makes `SendMessage`
  an *ask* rule. Claude Code then calls `--permission-prompt-tool mcp__mochi__approve`, which shows the
  approval card and answers allow/deny, so no message reaches another session unless the user presses Send.
- A message counts as sent only when Claude Code reports `success`. Mochi then watches that project's hook
  events and says when the session finishes or needs the user.
- `VoiceInput` streams the microphone through `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+) only while
  the shortcut is held.

## The iPhone companion

`iOS/MochiPocket.xcodeproj` holds:
- **MochiPocket**, a SwiftUI app. It pairs with the Mac by QR code and talks to it through Mochi Link
  (`PocketLink`), registers its push addresses with the relay, and has a preview and test buttons.
- **MochiLiveActivity**, the WidgetKit Live Activity (it opens the sealed title and detail with `LinkSeal`).
- **MochiNotifications**, the notification service extension that opens sealed alerts.
- **Shared/**, the `MochiActivityAttributes` wire model, the views and the art catalogue.

`Signing/MacSigning.xcodeproj` is a placeholder macOS target that lets Xcode register the Mac app's App ID
and create the profile for the optional team-signed build. The Mac app itself needs no profile: it claims
no iCloud or other restricted entitlement. See LIVE_ACTIVITY.md.

## Extending: new event providers

Implement `EventProvider` and deliver sanitized `WireEvent`s (or have your tool call
`mactamagotchi-hook report …`). Sessions, history, privacy rules, notification policy and reactions apply
unchanged. Good candidates: Xcode/Flutter build results, test runners, git hooks, other coding agents
with documented event APIs — always with explicit user consent.
