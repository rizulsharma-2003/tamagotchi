# Sprint 2: Windows matches the Mac, Android matches the iPhone

**Goal:** Every feature of the Mac app is built into Mochi for Windows, and the Android app closes its remaining gaps with Mochi Pocket for iPhone.

**Planned:** 2026-11-07.
**Code:** Windows is `flutter/apps/mochi_desktop`. Android is `flutter/apps/mochi_pocket`. Shared Dart packages are `mochi_link`, `mochi_art`, `mochi_ui`, `mochi_wire` and `mochi_world`.
**Reference:** the Mac app (`Sources/App`, `Sources/TamagotchiCore`) and the [README feature list](../README.md#features).

---

## Progress
| Date | Done |
|---|---|
| 2026-11-07 | **W29** install and signed auto-update (Windows 0.2.0, 0.2.1 on the user's PC) · **A6** Updates history · **A8** notification actions (Android) |
| 2026-11-08 | **W1** Windows toasts · **W2** the PC's rhythm · **W3** notify only when away · **W4** global shortcuts · **W10** summaries parity (Windows 0.2.2) |
| 2026-11-08 | **A1** Mochi on the Android lock screen while Claude works (relay 1.4.0 deployed; reached the Realme by FCM with the app closed) · **A3** hold to talk (Android) |
| 2026-11-08 | **G1** Mochi's world in Dart (`mochi_world`, matching the Mac on golden fixtures from Swift) · **G2** celebrations from real Claude events (the classifier; wiring into Windows and Android still to do) |
| 2026-11-08 | Logic in `mochi_world` for **W11** speech, **W12** growing up, **W14** games, **W15** focus, **W16** recap, **W18** room and **W20** holidays (6 more golden fixtures from Swift; UI still to do) |
| Parked | Multi-host rooms (docs/MULTI_HOST_PLAN.md), by the user's decision |

## Where Sprint 1 left us

| | Done |
|---|---|
| **Mochi Link** | The E2E relay (v1.2.1) is the only path between devices. It carries APNs for the iPhone, FCM for Android and Mochi Cloud. iCloud is gone (plan phases 0–6). |
| **Mac** | A Settings tab called **Phones** with device-aware wording. Link state is encoded deterministically (the rate-limit fix). |
| **iPhone** | No iCloud. Device-aware wording ("your Mac" or "your PC"). |
| **Android** | Pairing, the room, cards, approvals, Updates, notifications through FCM (even with the app closed), read-aloud with Settings › Voice, Appearance (System/Light/Dark), and the iPhone's look (Nunito and the UI/UX Pro Max pass). |
| **Windows** | Tray. Mochi walks **inside the taskbar's empty stretches** (UIA zones, click-through, speech bubbles), using about 8% of one core. Claude Code hooks with Connect/Remove, sessions, the Mochi Link host (pair phones, alerts, commands), basic Ask Mochi, and **Settings in the Mac's 12-pane layout**. Patch (taskbar + main-window room) is in progress. It is tested on a Windows 11 ARM VM: 188 tests. |

---

## How we work in Sprint 2

- **The Mac is the specification.** Each item lists the Mac code to read. Match its behaviour, wording and settings, and adapt only where Windows or Android differs.
- **No dead switches.** A setting must either work or say "Not on Windows yet". When an item ships, remove its "Not on Windows yet" row.
- **Wording names the real devices:** "your Mac" or "your PC", and phones by name and type (`LinkPeerNames` in mochi_link).
- **Done means:** tests (light and dark, 1× and 2× text, keyboard and screen reader), `flutter analyze` clean, verified on the Windows VM or the Realme with screenshots, installed for the user.
- **Privacy is the same as on the Mac** (docs/PRIVACY.md): allow-listed hook data, no prompts or file contents leaving the machine, and Ask Mochi sends only what you ask.
- **Size:** S is under one session, M is one to two sessions, L is three or more.

---

## Shared groundwork (do first: it unlocks most of Windows *and* Android)

### G1 · Mochi's world in Dart (`packages/mochi_world`) · L
Port the Mac's pet-life engine from `Sources/TamagotchiCore` to a pure-Dart package that Windows (and later Android) runs.
- **Scope:**
  - `CompanionWorld`: moods, needs and the living idle.
  - **38 pet animation states** and **33 companion states**, with follow-through.
  - **16 interaction scripts** (coffee delivery, show-and-tell, rock-paper-scissors, keeping watch, high five, victory dance, tiny trophy, detective mode, case closed, graduation, synchronized dance, …) on the weighted, seeded scheduler (cooldowns, daily caps, anti-repeat).
  - Play, treat and petting variants.
  - **Friendship and achievements** (local, never decreasing, daily caps) and **growing up** (kitten → young → grown-up).
- **How:** pure Dart with no Flutter, golden-tested against the Swift behaviour using the same seeds (shared fixtures in `link-spec/` style).
- **Acceptance:** the same seed gives the same script choices as the Mac; the Windows pet and the room run on it; Android can opt in (A5).
- **Built (2026-11-08; not yet wired into the apps):**
  - **What's ported.** `flutter/packages/mochi_world`, pure Dart with no dependencies. `MochiWorld` is `CompanionWorld` without the menu-bar roamer. It also has:
    - both animation state machines, and every pet and companion pose with follow-through, every play, treat and petting variant;
    - the 16 interaction scripts and their seeded scheduler;
    - sessions, reactions and the notification policy;
    - friendship, achievements and growing up;
    - persistence of progress and the recent event history.
  - **Golden fixtures.** `Tests/TamagotchiCoreTests/WorldFixture*.swift` writes `link-spec/world/*.json` from the Swift engine and fails if they drift. The Dart tests replay them (103 tests):
    - every pose in many contexts;
    - 14,200 scheduler steps;
    - progress step by step;
    - 5 whole world timelines with 165 snapshots of state, effects and frames.
  - **Not ported** (each its own item): the roamer and den, adventures (W19), speech lines (W11), games (W14), the focus timer (W15), the daily recap (W16), seasons and the room catalogue. The logic of W11–W20 (except W13, W17 and W19) followed later on 2026-11-08; see the rows below.
  - **How the apps drive it:** docs/MOCHI_WORLD.md.

### G2 · Celebrations from real Claude events · M
Port the event classification behind celebrations (`commandKind`: build/test detection, long-turn detection, repeated tool errors).
- High five for a finished turn, victory dance for a long turn (only when both ends were seen live), **trophy for real build/test results**, detective mode → case closed, graduation for milestones.
- Never for simulated or late events.
- **Built (2026-11-08; the classifier only, wiring still to do):**
  - **Where it lives.** In `mochi_world` (`Celebrations`, on the same `SessionRegistry` and `EventToAnimationMapper` the world uses), because the decision needs the session's turn, its tool errors and its build/test results, not just the hook event. `mochi_wire` stays the transport.
  - **What it answers.** It tells why an event celebrates: turn finished, long turn, build/test passed, investigating, case closed, first milestone, milestone or commit. It never answers for simulated, late or restored events.
  - **Checked against Swift.** `link-spec/world/celebrations.json` holds 17 timelines, with their transitions, reactions, notification decisions and celebrations, plus 40 commands. `mochi_wire`'s `CommandClassifier` is checked against the same commands.
  - **Still to do.** Use it in the Windows pet and room (W11–W18), and on Android (A5).

---

## Windows backlog (Mac → Windows)

### Must-haves first (quick wins)
| # | Feature (Mac reference) | Windows approach | Size |
|---|---|---|---|
| W1 | **Notifications** with per-category animate/badge/banner/sound, quiet hours, quiet mode and batching, and nothing for simulated or late events (Settings › Notifications) | Windows toast notifications for an unpackaged app (Start-menu shortcut with an AppUserModelID; WinRT through FFI or a vetted plugin). Sounds through the system player. | M |
| W2 | **Your PC's rhythm**: naps when the PC rests, wakes when you're back, stays up for video/calls/busy CPU (`Features/Rest/MacUsageMonitor`) | `GetLastInputInfo`, power and display notifications (`RegisterPowerSettingNotification`), session switch (`WTSRegisterSessionNotification`), presentation state, CPU load. Read only the time since the last input. | M |
| W3 | **"Notify me only when I'm away"** for phones | Uses W2's idle signal. | S |
| W4 | **Global shortcuts**: show/hide the pet (the Mac's ⌃⌥⌘P) and Ask Mochi (the Mac's ⌥Space) | `RegisterHotKey`, user-configurable in Settings, with conflict detection. | S |
| W5 | **Copy Cloud Settings** (Mochi Cloud joins the PC's room) | `LinkHost` cloud-invite call, as in `AgentController.copyCloudLinkSettings`. | S |
| W6 | **iPhone Live Activity from a PC** | Port `LiveActivityPlanner` and `LinkPush.liveActivity` (K_la sealing), and send `liveActivity` frames through the relay. Fixes the wrong "needs a Mac" note. | M |
| W7 | **Desktop pet options**: sizes, click-through mode, always on top, per-display position memory, styles (*Roams the taskbar* / *Plays in its spot* / *Classic tray icon*), "Patch only for interesting moments" | Settings › Desktop Pet. Per-monitor positions via `MonitorFromWindow`. | M |

### Claude features
| # | Feature | Windows approach | Size |
|---|---|---|---|
| W8 | **Full Ask Mochi**: approval card before anything is sent, **messages to your other Claude sessions** ("Message from @mochi"), "Claude finished in X" follow-ups, replies to a specific session from a phone (`Features/Assistant`: BrainSession, PawsServer) | The same `claude -p` helper session and permission-prompt tool on Windows. The mcp__mochi__* tools go through the hook bridge. Cross-session messaging through Claude Code's own mechanism, never typing into windows. | L |
| W9 | **Ask Mochi controls the PC**: open apps and links, bring windows forward, media keys, run tasks (`MacActions`) | An allow-list of actions: `ShellExecute`, UI Automation for focusing windows, `SendInput` only for media keys, and Power Automate / scheduled tasks instead of Shortcuts. Every action is shown on a card first. | L |
| W10 | **Turn summaries and replies** parity checks (the Mac's `TurnSummaryRunner`) | Check that the Windows host produces the same cards and summaries (Haiku through `claude -p`) as the Mac. | S |

### Mochi's life and fun (needs G1)
| # | Feature (Mac reference) | Size |
|---|---|---|
| W11 | **Mochi talks**: speech bubbles for greetings, Claude events, petting and sleepy mumbles; chattiness quiet/normal/chatty (`Features/Speech`). Fresh lines come from Claude Haiku on Windows, not Apple Intelligence. **Logic in mochi_world (2026-11-08); UI still to do:** `SpeechLines` and `SpeechPacing` match the Mac's fixture; `SpeechDirector` ports when to speak; Haiku plugs into its `FreshLineWriter` hook with the Mac's prompt. | M |
| W12 | **Mochi grows up**: kitten → young → grown-up art over weeks of friendship (`Features/Growth`). **Logic in mochi_world (2026-11-08); UI still to do:** `LifeStage` (G1) and `Growth.check` (the once-per-stage announcements). | S (after G1) |
| W13 | **Progress**: friendship hearts and achievements UI | S |
| W14 | **Mini-games**: Catch the Treats (arrow keys or drag, combos, golden treats, high score) and rock-paper-scissors with Mochi and Patch (`Features/Games`). **Logic in mochi_world (2026-11-08); UI still to do:** `CatchGame` (whole games match the Mac's fixture step for step), `RPSMatch`, `GameRecords`, and the stage's timing and poses (`RPSStage`). | M |
| W15 | **Focus buddy**: Pomodoro; Mochi naps while you focus, non-urgent sounds stay quiet, wake for a stretch (`Features/Focus`). **Logic in mochi_world (2026-11-08); UI still to do:** `FocusTimer` and `FocusLog` match the Mac's fixture; `FocusBuddy` naps Mochi, logs blocks and shows each transition. | M |
| W16 | **Daily recap** at 18:00: sessions, turns, tool calls, test runs, errors, focus minutes and streak; save or copy as an image (`Features/Recap`). **Logic in mochi_world (2026-11-08); UI still to do:** `DailyRecap` matches the Mac's fixture; `EventJournal` keeps the week from `onRecord`; `RecapSchedule` announces at 18:00. The card and its image are still to draw. | M |
| W17 | **Share a clip**: a 5-second looping GIF drawn by the app, never a screen capture, saved to Downloads (`Features/Share`) | M |
| W18 | **Room makeover**: twelve furniture pieces unlocked by friendship and achievements; Decorate and drag (`Features/Room`). **Logic in mochi_world (2026-11-08); UI still to do:** `FurnitureCatalog` (with the unlocks) and `RoomLayout` (placement, the Mac's `room` JSON) match the Mac's fixture. | M |
| W19 | **Explore the desktop**: drag Mochi off the taskbar and it walks along window tops, sits on the taskbar, climbs a screen edge and hops home; occasional spontaneous adventures (`Features/Adventure`). Uses `EnumWindows` rectangles only. | L |
| W20 | **Holidays, the rest**: seasonal treats, decorations on the taskbar strip, costumes on both characters (the art exists; the treats don't yet). **Logic in mochi_world (2026-11-08); UI still to do:** `SeasonCalendar` matches the Mac's fixture for every day of 2025–2030; `SeasonDecor`, `TreatStyle` and `SeasonTracker` give the costume, the treat and the once-per-occasion greeting. | S |
| W21 | **Feel the purr**: press and hold Mochi to keep it purring. No Force Touch on PCs, so use a purr sound with a gentle visual. | S |
| W22 | **The notch is Mochi's den** has no notch on Windows. Equivalent: a den by the tray or clock area where Mochi naps, peeks out when Claude needs you and bursts out to celebrate. | M |

### Agent
| # | Feature (Mac reference) | Windows approach | Size |
|---|---|---|---|
| W23 | **Mochi's agent**: Gmail, Calendar and Notion through the user's Claude connectors; checks every few minutes; morning briefing; "what's pending?"; quiet hours; VIPs; newsletters kept off the phone; ✓ done synced with the phones; meeting heads-ups with Join; reply drafts (`Features/Agent`, `TamagotchiCore/Agent`) | Port the agent runner (Claude Haiku through `claude -p` with read-only tools), the pending card and done sync over Mochi Link. Settings › Agent becomes real. | L |

### Voice
| # | Feature | Windows approach | Size |
|---|---|---|---|
| W24 | **Hold to talk** to Ask Mochi (the Mac uses on-device SpeechAnalyzer) | Windows on-device speech recognition (WinRT `Windows.Media.SpeechRecognition`) or local Whisper. The microphone is used only while the shortcut is held. | L |
| W25 | **Mochi's voice** (read aloud, Mochi's character presets) | Windows OneCore/SAPI voices with Mochi's pitch and pace, as on Android. Kokoro stays parked (espeak-ng GPL). | M |

### Polish and platform
| # | Item | Size |
|---|---|---|
| W26 | **Two windows at once** (the pet and the main window): Flutter 3.35 has one window per app. Use Flutter's multi-window support when it's stable, or a second native window or engine for the pet. | M |
| W27 | **Desktop widget**: a "Mochi & Claude" card in the Windows Widgets board (Windows App SDK widget provider; needs a packaged app, so it waits for W29) | L |
| W28 | **Developer pane**: event simulator and animation preview (the Mac's Developer settings) | M |
| W29 | **Installer and updates**: MSIX or Inno Setup, Start menu entry, uninstall, auto-update, code signing (Store and Developer ID are still parked; see the Mochi Link plan, phase 7). **Pulled forward (2026-11-07):** Mochi installs itself per user (`%LOCALAPPDATA%\Programs\Mochi`, a Start-menu shortcut with the AUMID `InsideEdge.Mochi`, a Settings › Apps entry whose uninstall runs `mochi_hook uninstall`) and updates itself from the user's own relay (relay 1.3.0, KV `UPDATES`), Ed25519-signed and SHA-256-checked; releases come from `scripts/release-windows.sh`. Still open: MSIX and code signing. | M |
| W30 | **Performance budget**: target the Mac's 1–2% CPU when calm and 3–4% when roaming (today about 8%), and idle RAM under 120 MB | M |
| W31 | **Native ARM64 build** when the Flutter version we move to supports it (today Mochi runs as x64 under emulation on ARM PCs) | S (an upgrade spike) |

### Windows extras: crazier than the Mac (approved by the user 2026-11-07)
Windows lets an app see and nudge much more of the desktop than macOS does, so Mochi gets to be wilder here. **Rules for every extra:**
- Mischief is opt-in, behind one "Mischief" master switch plus a switch per extra.
- Mochi never takes your keyboard or pointer, never closes or minimises anything, and never types into apps.
- Everything it moves is put back.
- It stays still during presentations, full-screen apps and games (W2), and respects quiet hours (W1).

| # | Extra | How on Windows | Size |
|---|---|---|---|
| N1 | **Native stage**: a small C++ component that draws characters and effects anywhere on screen at native speed, controlled from Flutter over a method channel. Mochi and Patch can roam the whole desktop, several windows exist at once (also solves W26), and full-screen effects stay cheap. | `DirectComposition` + `Direct2D`, layered click-through windows, a per-character hit test | L |
| X1 | **Title-bar walker**: Mochi walks along any window's title bar, jumps between windows, hangs on when you drag that window and drops off when you snap or minimise it | `EnumWindows`, `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`, a `SetWinEventHook` move/size hook; extends W19 | L |
| X2 | **Mischief mode**: nudges a window a few pixels, sits on its edge so it wobbles, tugs your terminal when Claude needs you; everything is restored afterwards | `SetWindowPos` on other apps' windows (same integrity level only), with undo | M |
| X3 | **Peekaboo**: peeks out from behind windows, hides behind the one you're using, pops out when you come back | Z-order placement relative to the foreground window | M |
| X4 | **Cursor buddy**: follows or chases your pointer, pounces beside it, sits on it while you're idle; never moves or hides the pointer | `GetCursorPos` polling only | S |
| X5 | **Desktop icon play**: sits on desktop icons, nudges one, then puts it back | The desktop's `SysListView32` positions (LVM_GETITEMPOSITION / SETITEMPOSITION), saved and restored | M |
| X6 | **Landmarks**: naps in the Recycle Bin, swings on the clock, plays by the Start button, perches on the widgets tile | UI Automation positions (as for the taskbar zones) | M |
| X7 | **Reacts to what you do**: dances to music, goes quiet during calls, hides during games, perks up when you open your editor or terminal | Media session API (`GlobalSystemMediaTransportControlsSessionManager`), microphone in use (privacy registry consent store), foreground app via `GetForegroundWindow` (process name only, never contents) | M |
| X8 | **Multi-monitor roaming**: walks from one screen to the next and follows you to the screen you're using | `EnumDisplayMonitors`, the foreground window's monitor | M |
| X9 | **Sticky notes from Mochi**: little notes left on the desktop ("Claude finished the tests ✓", "stretch break?") that you can dismiss or pin | Small native-stage windows | S |
| X10 | **Full-screen celebrations**: confetti for big wins (graduation, all tests green), fireworks for streaks, all drawn on the native stage | N1 | M |
| X11 | **Holiday takeover**: snow settling on every window top, Diwali lights along title bars, pumpkins on the taskbar | N1 + X1's window geometry | M |
| X12 | **Weather and time moods**: Mochi brings an umbrella when it rains (local weather, opt-in), yawns late at night, has morning coffee with Patch | A weather API with coarse location (opt-in), the local clock | S |

### Ask Mochi on Windows (beyond W8/W9/W24)
| # | Feature | How | Size |
|---|---|---|---|
| X13 | **Drop a file on Mochi** (or Patch) to ask about it: "what's in this PDF?", "summarise this log", "fix this file with Claude" | OLE drag-and-drop target on the pet window; the path goes to the Ask Mochi helper and the file is read only by Claude Code on this PC | M |
| X14 | **Drop text or a link on Mochi** to ask about it or send it to a Claude session | Drag-and-drop text/URL formats | S |
| X15 | **Ask about the clipboard**: "explain what I copied" from the pop-up or the shortcut, sent only when you press Send | The clipboard is read only on that action | S |
| X16 | **Ask Mochi everywhere**: from the taskbar pop-up, the global shortcut (W4), the tray, a Start-menu jump list and the phones (already works) | Jump list through `ICustomDestinationList`; a pop-up text field | S |
| X17 | **"What's on my screen?"** (opt-in, per request): sends a screenshot of the active window to Claude with your question, after a preview card you approve | `PrintWindow` of the foreground window only, shown before sending; never automatic | M |

---

## Android backlog (iPhone → Android)

| # | Feature (iPhone reference) | Android approach | Size |
|---|---|---|---|
| A1 | **Live Activity equivalent**: Mochi on the Lock Screen and status bar while Claude works, lighting up when Claude needs you and celebrating when done. **Built (2026-11-08; checked on the Realme against a local 1.4.0 relay, socket path):** an ongoing notification updated in place (plugins/mochi_live_update): the iPhone's scene per phase and pose, the timer, Open and Open the Session; "When Claude needs you" lights up with a sound; ends as on the iPhone (End It, `activityEnded`); Settings › Lock screen with a sample per phase. Relay 1.4.0 (deployed 2026-11-08; a real start from the Mac reached the Realme by FCM with the app closed) pushes `liveActivity` to Android by FCM and to its socket; K_la vectors in link-spec/live-activity.json. The Mac now sends it with only an Android phone paired. Android 16 Live Update promotion not yet seen on a phone. | An ongoing notification (Android 16 *Live Updates* / progress-style, falling back to a standard ongoing notification), updated by FCM data messages. **The relay needs Android `liveActivity` delivery through FCM**; today Live Activity frames go to APNs only. | L |
| A2 | **Home-screen widget**: "Mochi & Claude" with Waiting for you, like the iPhone Lock Screen widget (`iOS/MochiWidgets`) | An AppWidget (Glance), updated from the app and FCM | M |
| A3 | **Hold to talk**: press and hold Mochi, Mochi listens, and the request runs on the computer (`TalkModel`, `PhoneListener`). **Built (2026-11-08; the listening UI, the microphone question and the on-device recognizer checked on the Realme; no speech there at night):** the listening pose and sound waves, words as they're heard, let go to send, slide away to cancel, the 45 s answer timeout, a Talk button (tap, then Send) and a TalkBack action. | Android on-device `SpeechRecognizer` (offline when available) | M |
| A4 | **"Hey Google" instead of Siri**: "What's waiting on Mochi?" and similar phrases (`MochiIntents`) | App Actions / Shortcuts (capabilities.xml), a Quick Settings tile and app shortcuts. Read the answer in Mochi's voice. | M |
| A5 | **Full pet simulation in the room**: the iPhone runs `CompanionWorld`; Android plays recorded poses | Use G1 `mochi_world` | M (after G1) |
| A6 | **Updates history**: a week of history grouped by day, like the iPhone (today: waiting and done only). **Built (2026-11-07; not yet checked on the Realme):** every card's items kept a week (`updates.json`, also from the push handler), shown by day under Waiting for you with when each came in and where and when it was marked done. | S |
| A7 | **Mochi Cloud on the phone**: "Check now" through Mochi Cloud when the computer is off, and **reply drafts** | Read the agent state from the room; trigger the cloud check like the iPhone | M |
| A8 | **Notification actions**: Reply to a session from the notification, Join, Mark done, Approve/Decline. Match the iPhone's categories (`PhoneNotifications`). **Built (2026-11-07; checked against the live relay, not yet on the Realme):** Reply (RemoteInput), Join, Open in Gmail and Mark done; Reply and Mark done work with the app closed (a background isolate sends them over HTTPS, or they wait for the app). No Approve/Decline: the iPhone has no approval notification. | Notification actions with RemoteInput | M |
| A9 | **Mochi's voice upgrade**: a licence-clean neural voice (Kokoro with a non-GPL phonemiser) | Spike: research only | S |
| A10 | **Play Store release**: listing, privacy form, signing (parked with phase 7 until the user unparks it) | M |

---

## Suggested order

1. **Week 1, quick wins:** W1, W2, W3, W4, W5, W6, W10, A6, A8.
2. **Week 2, Claude power:** W8, then W9 (with the safety review). In parallel: A1 (with relay support) and A3.
3. **Weeks 3–4, Mochi's life:** G1, G2, then W11–W18 and A5.
4. **Week 5, agent and voice:** W23, W24, W25, A4, A7.
5. **Week 6, polish:** W7, W19–W22, W26–W31, A2.
6. **Weeks 7–8, Windows extras:** first X4, X7, X13–X16 in Flutter (cheap and fun, measured on a real PC). Then N1 (the native stage), then X1, X3, X6, X8, X10, X11, then X2, X5, X9, X12, X17.

Each item ships on its own: merged, tested, installed and screenshotted, so the user sees progress daily.

## Risks and decisions

| Risk | Plan |
|---|---|
| Porting the pet-life engine (G1) drifts from the Mac | Shared seeds and fixtures, plus golden tests against Swift output |
| Windows toasts need an app identity | A Start-menu shortcut with an AUMID now; MSIX later (W29) |
| PC control (W9) could do something unwanted | An allow-list, a card before every action, no typing into other apps; the same rules as the Mac |
| Flutter has one window per app | W26 |
| ARM PCs run the x64 build | Fine for testing; W31 when Flutter supports native ARM64 |
| Relay changes for Android Live Updates (A1) | Additive protocol change with relay tests, deployed like 1.2.x |
| Mischief extras annoy the user or look like malware (X2, X5) | Opt-in, one master switch, undo for every move, never keyboard, pointer, closing or typing. Pause during presentations and full screen. Explain each extra in Settings. |
| Full-screen effects cost too much in Flutter | The native stage N1 (hybrid: Flutter stays the app, C++ only draws) |
| "What's on my screen?" (X17) is privacy-sensitive | Per request only, the active window only, a preview card before sending, never stored |
