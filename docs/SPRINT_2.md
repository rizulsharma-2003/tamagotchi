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
| 2026-11-08 | **W30** performance (pictures of poses, nothing running while the screen can't be seen) · **W7** desktop pet options · **W5** Copy Cloud Settings (built and tested; not yet checked on the Windows VM or released) |
| 2026-11-08 | Logic in `mochi_world` for **W11** speech, **W12** growing up, **W14** games, **W15** focus, **W16** recap, **W18** room and **W20** holidays (6 more golden fixtures from Swift; UI still to do) |
| 2026-11-08 | **A7** Mochi Cloud on the phone (Check now while the computer is off, Draft a reply) · **A2** the "Mochi & Claude" home-screen widget · **A4** hands-free: Quick Settings tile, app shortcuts, Hey Google (Android) |
| 2026-11-08 | Mochi's life on Windows, part 1: **G1** and **G2** wired in (one `MochiWorld` drives Mochi and Patch on the taskbar, the desktop, the popover and Mochi's window; celebrations from real Claude events only) · **W11** Mochi talks · **W12** Mochi grows up · **W13** Progress (built and tested on the Mac; not yet checked on the Windows VM or released) |
| 2026-11-08 | **A5** Mochi's full life in the Android room: one `MochiWorld` follows the computer as the iPhone's does (Claude's state as simulated events that never count, petting both ways, the look and today's holiday), ticking only while the room can be seen (checked on the Realme in a test room) |
| Parked | Multi-host rooms (docs/MULTI_HOST_PLAN.md), by the user's decision; with it **W6** (a Live Activity from a PC: the iPhone isn't paired with the PC) |

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
- **Wired into Windows (2026-11-08; not yet checked on the Windows VM):**
  - **One world.** `DesktopWorld` (`mochi_desktop/lib/src/core/desktop_world.dart`) owns the one `MochiWorld`. In go Claude Code's hook events (live from the bridge, late from the spool), the PC's rhythm (W2, so Mochi naps while the PC rests and wakes with a stretch), Settings under the Mac's keys, and this PC's own moments (petting here or from a phone, Ask Mochi, updates). It ticks at 4 Hz while the screen can be seen and not at all while it can't, and keeps progress, the seed and the last three hours of real events in `world.json` (no paths, prompts or notification text).
  - **It drives everything Mochi and Patch do:** their loops, Claude's moments, petting, the moments they share (the Mac's scheduler with this install's seed), naps, Patch's arrivals and departures. The taskbar pet keeps W30's pictures: the world's loops play on a seamless 5-second ring so their poses repeat and are drawn once; its moments are drawn from the art. On the Mac's software rasterizer (`tool/sprite_bench_test.dart`) a frame from the world's loops costs 74% less with pictures, as with the recordings, and more of them are reused (155 of 200 walking frames, 84 of 96 idle ones). The room in the popover and Mochi's window draws the world's frame as it is. The stroll holds Mochi still while the world reacts (the Mac's roamer freezes); a moment together runs from Mochi's spot to Patch's desk.
  - **Notifications and sounds.** Claude's moments keep their Windows notifications, sounds and badge in W1's `Reactions` (the same Mac rules), so nothing is said twice; the world's own moments (achievements, petting, growing up) reach the same toasts and sounds.
  - **One set of types.** `mochi_art` depends on `mochi_world` and re-exports its model, so the world's poses go straight to the renderers.
- **Wired into Android (2026-11-08):** the room runs one `MochiWorld` (`mochi_pocket/lib/src/scene/phone_world.dart`); see A5.

### G2 · Celebrations from real Claude events · M
Port the event classification behind celebrations (`commandKind`: build/test detection, long-turn detection, repeated tool errors).
- High five for a finished turn, victory dance for a long turn (only when both ends were seen live), **trophy for real build/test results**, detective mode → case closed, graduation for milestones.
- Never for simulated or late events.
- **Built (2026-11-08; the classifier only, wiring still to do):**
  - **Where it lives.** In `mochi_world` (`Celebrations`, on the same `SessionRegistry` and `EventToAnimationMapper` the world uses), because the decision needs the session's turn, its tool errors and its build/test results, not just the hook event. `mochi_wire` stays the transport.
  - **What it answers.** It tells why an event celebrates: turn finished, long turn, build/test passed, investigating, case closed, first milestone, milestone or commit. It never answers for simulated, late or restored events.
  - **Checked against Swift.** `link-spec/world/celebrations.json` holds 17 timelines, with their transitions, reactions, notification decisions and celebrations, plus 40 commands. `mochi_wire`'s `CommandClassifier` is checked against the same commands.
  - **Wired into Windows (2026-11-08; not yet checked on the Windows VM).** Mochi's world celebrates exactly these, from the bridge's live events; `DesktopWorld` feeds the classifier every event in order (restored history too, which never celebrates), tells the screen reader, and brings Patch out for them with "only for interesting moments". Simulated activity doesn't reach Mochi's world on Windows at all (as it doesn't reach the sessions). The popover has the Mac's **Milestone** button (graduation the first time). Tested end to end: never for simulated, late, restored or repeated events.
  - **Android (A5, 2026-11-08).** Nothing to wire: the phone mirrors the computer's Claude as simulated events, which never celebrate (the computer celebrates the real ones). The world's own reactions still play there, as on the iPhone: a high five for a finished turn, a wave while Claude waits.

---

## Windows backlog (Mac → Windows)

### Must-haves first (quick wins)
| # | Feature (Mac reference) | Windows approach | Size |
|---|---|---|---|
| W1 | **Notifications** with per-category animate/badge/banner/sound, quiet hours, quiet mode and batching, and nothing for simulated or late events (Settings › Notifications) | Windows toast notifications for an unpackaged app (Start-menu shortcut with an AppUserModelID; WinRT through FFI or a vetted plugin). Sounds through the system player. | M |
| W2 | **Your PC's rhythm**: naps when the PC rests, wakes when you're back, stays up for video/calls/busy CPU (`Features/Rest/MacUsageMonitor`) | `GetLastInputInfo`, power and display notifications (`RegisterPowerSettingNotification`), session switch (`WTSRegisterSessionNotification`), presentation state, CPU load. Read only the time since the last input. | M |
| W3 | **"Notify me only when I'm away"** for phones | Uses W2's idle signal. | S |
| W4 | **Global shortcuts**: show/hide the pet (the Mac's ⌃⌥⌘P) and Ask Mochi (the Mac's ⌥Space) | `RegisterHotKey`, user-configurable in Settings, with conflict detection. | S |
| W5 | **Copy Cloud Settings** (Mochi Cloud joins the PC's room) | `LinkHost` cloud-invite call, as in `AgentController.copyCloudLinkSettings`. **Built (2026-11-08):** `LinkHost.joinCloud` invites for the cloud role and joins as "Mochi Cloud", then removes the cloud device it had (first when the room is full, never when joining failed), so there's only ever one; the `MOCHI_LINK_*` block with `MOCHI_TIMEZONE` (the IANA zone, through ICU) goes on the clipboard. Settings › Agent asks before replacing, and says the agent itself isn't on Windows yet. Checked live in a throwaway room (`test/cloud_live_test.dart`). | S |
| W6 | **iPhone Live Activity from a PC** | Port `LiveActivityPlanner` and `LinkPush.liveActivity` (K_la sealing), and send `liveActivity` frames through the relay. Fixes the wrong "needs a Mac" note. | M |
| W7 | **Desktop pet options**: sizes, click-through mode, always on top, per-display position memory, styles (*Roams the taskbar* / *Plays in its spot* / *Classic tray icon*), "Patch only for interesting moments" | Settings › Desktop Pet. Per-monitor positions via `MonitorFromWindow`. **Built (2026-11-08):** the three styles (in Settings, the tray menu and the pet's menu; off the taskbar is the classic tray icon, a port of the Mac's MenuBarGlyph as .ico frames), the spot's room, Small/Medium/Large, Always on top, click-through, a place per display (EnumDisplayMonitors), Patch only for interesting moments (taskbar). Not yet: Patch beside the desktop pet off the taskbar (the Mac's desktop pet shows him there). | M |

### Claude features
| # | Feature | Windows approach | Size |
|---|---|---|---|
| W8 | **Full Ask Mochi**: approval card before anything is sent, **messages to your other Claude sessions** ("Message from @mochi"), "Claude finished in X" follow-ups, replies to a specific session from a phone (`Features/Assistant`: BrainSession, PawsServer) | The same `claude -p` helper session and permission-prompt tool on Windows. The mcp__mochi__* tools go through the hook bridge. Cross-session messaging through Claude Code's own mechanism, never typing into windows. | L |
| W9 | **Ask Mochi controls the PC**: open apps and links, bring windows forward, media keys, run tasks (`MacActions`) | An allow-list of actions: `ShellExecute`, UI Automation for focusing windows, `SendInput` only for media keys, and Power Automate / scheduled tasks instead of Shortcuts. Every action is shown on a card first. | L |
| W10 | **Turn summaries and replies** parity checks (the Mac's `TurnSummaryRunner`) | Check that the Windows host produces the same cards and summaries (Haiku through `claude -p`) as the Mac. | S |

### Mochi's life and fun (needs G1)
| # | Feature (Mac reference) | Size |
|---|---|---|
| W11 | **Mochi talks**: speech bubbles for greetings, Claude events, petting and sleepy mumbles; chattiness quiet/normal/chatty (`Features/Speech`). Fresh lines come from Claude Haiku on Windows, not Apple Intelligence. **Logic in mochi_world (2026-11-08):** `SpeechLines` and `SpeechPacing` match the Mac's fixture; `SpeechDirector` ports when to speak; Haiku plugs into its `FreshLineWriter` hook with the Mac's prompt. **Built for Windows (2026-11-08; not yet checked on the Windows VM):** bubbles on the taskbar pet and the desktop pet (over Patch's desk for his lines) and in the room over whoever speaks; Settings › Fun › Talking with chattiness; fresh lines through `claude -p` (one request for every moment, every two hours while on; off by default here, as it uses your Claude Code; only the kind of moment is sent). | M |
| W12 | **Mochi grows up**: kitten → young → grown-up art over weeks of friendship (`Features/Growth`). **Logic in mochi_world (2026-11-08):** `LifeStage` (G1) and `Growth.check` (the once-per-stage announcements). **Built for Windows (2026-11-08; not yet checked on the Windows VM):** checked every minute ("Meet kitten Mochi!", then "Mochi grew up!" with a victory and a line once per stage, `lifeStageSeen`), drawn at its age everywhere; Settings › Fun › Growing up with where Mochi is and what it takes next. | S (after G1) |
| W13 | **Progress**: friendship hearts and achievements UI. **Built for Windows (2026-11-08; not yet checked on the Windows VM):** the popover's five hearts and points to the next level; Settings › Characters › Friendship with every achievement (what it takes, what it unlocks, when it was earned) and Reset Progress; things to wear unlock with achievements, as on the Mac; achievements reach you as Settings › Notifications says. | S |
| W14 | **Mini-games**: Catch the Treats (arrow keys or drag, combos, golden treats, high score) and rock-paper-scissors with Mochi and Patch (`Features/Games`). **Logic in mochi_world (2026-11-08):** `CatchGame` (whole games match the Mac's fixture step for step), `RPSMatch`, `GameRecords`, and the stage's timing and poses (`RPSStage`). **Built for Windows (2026-11-08; not yet checked on the Windows VM):** a Games page in Mochi's window (the Mac's Games window), opened from the popover's fun row, the tray's and the pet's Games… and Settings › Fun › Games › Play…. Catch the Treats is the Mac's picnic field drawn line for line (the treats, golden cookies, combos, lives, "Faster!", Ready/Paused/Game over cards); ← → or A D, dragging, Space to play or pause, Escape to pause; it pauses when the window loses the focus, closes or you switch games. Rock-paper-scissors: the stage with Mochi, Patch (unless he never shows) and your hand, the chant, Won/Lost/Draw, R/P/S or 1/2/3, the sitting's tallies and the all-time line. A pop, a chime, a jump, a note and a fanfare for a new record, as on the Mac; records under the Mac's `games` key, with Reset Records…. The field is drawn every frame only while a game is played (12 a second between games, none with animations off or while the screen can't be seen). | M |
| W15 | **Focus buddy**: Pomodoro; Mochi naps while you focus, non-urgent sounds stay quiet, wake for a stretch (`Features/Focus`). **Logic in mochi_world (2026-11-08):** `FocusTimer` and `FocusLog` match the Mac's fixture; `FocusBuddy` naps Mochi, logs blocks and shows each transition. **Built for Windows (2026-11-08; not yet checked on the Windows VM):** Focus in the popover's fun row (Stop while it runs) and the Mac's running row (the phase and time left, the set's blocks, a bar, Skip, Stop), Start/Stop Focus in the tray (the pet's menu says the time left, as the Mac's does) and Settings › Fun › Focus buddy (the Mac's lengths, naps, chime, notification; under the Mac's `focus` key). Mochi naps through a block (the taskbar's Mochi too), only what needs you makes a sound, a break wakes Mochi for a stretch and play with the Mac's lines, notes, chime and (if asked for) a Windows notification; a block the PC slept through isn't counted. Completed blocks are kept a week in `focus-log.json` for the recap. It ticks once a second only while a session runs and the screen can be seen; otherwise one wake at the phase's end. | M |
| W16 | **Daily recap** at 18:00: sessions, turns, tool calls, test runs, errors, focus minutes and streak; save or copy as an image (`Features/Recap`). **Logic in mochi_world (2026-11-08):** `DailyRecap` matches the Mac's fixture; `EventJournal` keeps the week from `onRecord`; `RecapSchedule` announces at 18:00. **Built for Windows (2026-11-08; not yet checked on the Windows VM):** an `EventJournal` fed by Mochi's world (real live and late events only, never simulated or restored ones, never paths), kept a week in `journal.json`. Today's Recap in Mochi's window (the popover's Recap, the tray's and the pet's Today's Recap…, Settings › Fun › Daily recap › Open Recap…): the Mac's card drawn by the app (Mochi and Patch presenting the day, the title, date and streak, the tiles, the line, the footer; always light), back a day at a time through the week, Copy Image (a PNG and a bitmap on white on the clipboard) and Save Image… (Ctrl+S; to Downloads, with Show in Folder, instead of the Mac's save panel). The evening announcement once per active day from the recap hour, checked each minute while the screen can be seen and 8 s after launch, with the Mac's note and line; its Windows notification (for users who asked) opens the recap. Settings › Fun › Daily recap under the Mac's `recap` key. | M |
| W17 | **Share a clip**: a 5-second looping GIF drawn by the app, never a screen capture, saved to Downloads (`Features/Share`) | M |
| W18 | **Room makeover**: twelve furniture pieces unlocked by friendship and achievements; Decorate and drag (`Features/Room`). **Logic in mochi_world (2026-11-08):** `FurnitureCatalog` (with the unlocks) and `RoomLayout` (placement, the Mac's `room` JSON) match the Mac's fixture. **Built for Windows (2026-11-08; not yet checked on the Windows VM):** the Mac's room editor over the room, with mochi_art's `RoomSpace`: Decorate in the popover's fun row decorates the popover's room (as on the Mac), and the tray's, the pet's and Settings' Decorate the Room… decorate the bigger room in Mochi's window. The tray of twelve (locked ones greyed with a lock and how to earn them), a click adds at a free spot, a drag places; placed pieces dragged within their band (which lights up), selected to Flip or put away, dropped on the tray to put away; at most eight. From the keyboard: Tab to a tray piece and Enter, Tab to a placed piece and the arrows, F, Delete; Escape or Done. Nobody is petted while decorating; a holiday's note waits for it. The room is drawn with its furniture everywhere (the popover, Mochi's window, Settings' preview), kept under the Mac's `room` key; Settings › Fun › Room lists what's placed (each can be put away), what's unlocked, Decorate… and Clear Room. | M |
| W19 | **Explore the desktop**: drag Mochi off the taskbar and it walks along window tops, sits on the taskbar, climbs a screen edge and hops home; occasional spontaneous adventures (`Features/Adventure`). Uses `EnumWindows` rectangles only. | L |
| W20 | **Holidays, the rest**: seasonal treats, decorations on the taskbar strip, costumes on both characters (the art exists; the treats don't yet). **Logic in mochi_world (2026-11-08):** `SeasonCalendar` matches the Mac's fixture for every day of 2025–2030; `SeasonDecor`, `TreatStyle` and `SeasonTracker` give the costume, the treat and the once-per-occasion greeting. **Built for Windows (2026-11-08; not yet checked on the Windows VM):** the Mac's SeasonController with `SeasonTracker`: refreshed at launch, 4 s later (with the greeting), on the hour and at midnight (with the world's minute check, so also when the screen comes back) and when the holiday settings change; each occasion greeted once with the Mac's line, hop and Patch celebrating, its note waiting until Mochi's window or popover opens; greeted occasions kept in `seasons.json`. The seasonal treat (candy, laddoo, gingerbread, cake, heart cookie), birthday candles and New Year's digits for the art; costumes on both characters everywhere they're drawn; a little decoration on the taskbar strip beside Patch's desk (a pumpkin, a diya, a tree…; where the Mac has it beside the bed in the menu bar), with Settings › Fun › Holidays' switch under the Mac's `seasonal.decorateMenuBar` and the Mac's status line. | S |
| W21 | **Feel the purr**: press and hold Mochi to keep it purring. No Force Touch on PCs, so use a purr sound with a gentle visual. **Built for Windows (2026-11-08; not yet checked on the Windows VM):** the Mac's PurrSession: press and hold Mochi for 0.3 s (on the taskbar, the desktop pet, or its room in the popover and Mochi's window) and it's petted at once and every 3 s you hold on (with the friendship's daily caps), purr lines tremble at its sides (still with animations off), and a soft synthesized purr plays in bursts a breath apart with Mochi's sounds on (never in quiet mode or hours, or while the screen can't be seen). Letting go or half a minute ends it, and its only timer with it. A click still pets (or opens the popover), a drag still moves Mochi before the hold. The screen reader has a Purr action. Settings › Fun › Touch: "Purr sound while you hold Mochi" under the Mac's `hapticPurr` key (greyed, with the reason, while sounds are off). | S |
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
| W30 | **Performance budget**: target the Mac's 1–2% CPU when calm and 3–4% when roaming (today about 8%), and idle RAM under 120 MB. **Done (2026-11-08):** each pose is drawn once into a picture at the display's scale and fraction of a pixel and reused (`PoseSprites`; the same pixels as the art), calm loops on the taskbar at 8 fps (no blink skipped), nothing at all while the screen can't be seen, UI Automation only when the taskbar changes (one cross-process call), the pointer checked twice a second during naps, precise timers only during the popover's transitions. A `perf-debug` file in Mochi's folder logs CPU and frames by state to `perf.log`. Before, on the VM (release build, no GPU, x64 under emulation): calm about 20–22% of a core at 12–13 fps (each frame 1.8 ms to build and 7–8 ms to raster), roaming about 27%. A frame of the taskbar pet costs 67% (walking) to 75% (resting) less to draw with pictures (tool/sprite_bench_test.dart, software rasterizer), and a calm loop on the taskbar is drawn a third less often. The after numbers on the VM are still to take (the VM became unreachable mid-measurement: the host Mac ran out of memory). | M |
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
| A2 | **Home-screen widget**: "Mochi & Claude" with Waiting for you, like the iPhone Lock Screen widget (`iOS/MochiWidgets`). **Built (2026-11-08; checked on the Realme in a test room, light and dark, 4 × 2):** Mochi's pose for what Claude is doing and what that is ("Claude finished!", "mac-Tamagotchi · on your Mac"), Claude's sessions with their status, and Waiting for you (meetings at the phone's own time format, VIPs starred), in the clay colours; sections leave before rows are cut, at any size and font size. Kept fresh by the app and, with Mochi closed, by the push handler (news cards, finished turns, Live Activities, Mark done), only for the room it shows; meetings leave and a long-silent "working" turns idle without the app (Android redraws it every 30 minutes). Taps open home, Claude's sessions or Updates. Settings › Home screen › Add to Home Screen. Not seen on the phone: a taller widget with the sessions (no free space to resize it on the home screen), 2× text (ColorOS doesn't let adb change the font size) and a Live Activity push reaching it with the app closed (a news push did). | An AppWidget with RemoteViews (no new dependency; Glance needs Compose) in the app, redrawn through a local plugin (plugins/mochi_home_widget) so the FCM push handler can update it | M |
| A3 | **Hold to talk**: press and hold Mochi, Mochi listens, and the request runs on the computer (`TalkModel`, `PhoneListener`). **Built (2026-11-08; the listening UI, the microphone question and the on-device recognizer checked on the Realme; no speech there at night):** the listening pose and sound waves, words as they're heard, let go to send, slide away to cancel, the 45 s answer timeout, a Talk button (tap, then Send) and a TalkBack action. | Android on-device `SpeechRecognizer` (offline when available) | M |
| A4 | **"Hey Google" instead of Siri**: "What's waiting on Mochi?" and similar phrases (`MochiIntents`). **Built (2026-11-08; the tile, the shortcuts and Assistant's links checked on the Realme):** "Talk to Mochi" in Quick Settings opens Mochi listening (Settings › Hands-free asks Android to add it); press and hold Mochi's icon for Talk to Mochi, What's waiting (Mochi reads it out in its own voice) and Check now; App Actions in `res/xml/shortcuts.xml` for "what's waiting", "check" and "talk" (the iPhone's Siri phrases) and OPEN_APP_FEATURE, with Mochi answering out loud. Hey Google itself is untested: Assistant only uses App Actions for apps from Google Play (A10). | App Actions / Shortcuts (capabilities.xml), a Quick Settings tile and app shortcuts. Read the answer in Mochi's voice. | M |
| A5 | **Full pet simulation in the room**: the iPhone runs `CompanionWorld`; Android plays recorded poses. **Built (2026-11-08; checked on the Realme in a throwaway test room driven by tool/fake_mac.dart, never the real room):** one `MochiWorld` runs the room (`scene/phone_world.dart`), as the iPhone's `PhoneWorld`: Mochi and Patch (always at his desk), their loops, the moments they share on the Mac's scheduler (a coffee delivery showed up on the phone), every pet, play and treat variant, naps. It follows the computer as the iPhone does: Claude's state there plays as simulated hook events for a mirror session, so Patch works the way Claude works, Mochi watches, waves when Claude needs you and high-fives a finished turn, and naps while the computer rests; none of it is counted, kept or announced (the computer owns friendship and achievements, and the header shows its level). Petting, play and treats go both ways, once (the computer counts the phone's; its own aren't sent back). The look gives the names, colours, room, things to wear and today's holiday (Diwali decorations and flower crowns on the phone tonight). Talking takes over Mochi's pose as on the iPhone (listen, nod, look around, bounce and smile, a worried look). TalkBack hears what Mochi and Patch are doing ("Mochi's room. Mochi is relaxing. Patch is at his desk."), with Mochi a button of its own; Settings › Mochi Link has the iPhone's "Room and pet: Following your Mac". Light on the battery: the world ticks and the room draws only while it can be seen (the app in front, the home screen showing, the room scrolled into view); every display frame only for your own moments, 30 frames a second for the others, 15 for the loops, 6 while both nap, at most 10 with animations off (the Mac's Reduce Motion poses). On the Realme (debug build): 15 fps for the loops, about 45% of a core with the room on screen against 91% for the recorded poses at display rate, and nothing (0.05–0.3%) behind Settings, scrolled away or in the background. The recorded poses (363 KB) are gone. Nothing is stored, as on the iPhone (its progress file for the phone's own petting is never shown; Android keeps that count in memory). Deliberate differences from the iPhone: the first state seen after launch sets the scene quietly (no high five for a turn that ended before you looked); a mirrored tool still running finishes before the next state, so Mochi keeps waving while Claude waits; no decorations for Mochi's own birthday (the look doesn't carry the adoption day). Not changed: no world speech (nothing makes the iPhone's world speak either) and Mochi stays grown up (the look has no life stage, as on the iPhone). Not seen on the phone: hold to talk (night), 2× text and TalkBack speaking (covered by tests; the labels were read from the phone's accessibility tree). | Use G1 `mochi_world` | M (after G1) |
| A6 | **Updates history**: a week of history grouped by day, like the iPhone (today: waiting and done only). **Built (2026-11-07; not yet checked on the Realme):** every card's items kept a week (`updates.json`, also from the push handler), shown by day under Waiting for you with when each came in and where and when it was marked done. | S |
| A7 | **Mochi Cloud on the phone**: "Check now" through Mochi Cloud when the computer is off, and **reply drafts**. **Built (2026-11-08; checked on the Realme against a stand-in Mochi Cloud, tool/fake_cloud.dart, never the real routine):** Check now goes straight to Mochi Cloud (Settings › Mochi Cloud › "Check now always asks Mochi Cloud", on by default) or to the computer first and to Mochi Cloud when it doesn't answer in 15 s; "Draft a reply…" on an email writes it into Gmail Drafts; Mochi Cloud's cards fold into Waiting for you as on the iPhone (an hourly card only adds); the card says when Mochi Cloud is checking, what went wrong, or how to set it up on the computer, by name. The trigger's token goes only to Anthropic's API. | Read the agent state from the room; trigger the cloud check like the iPhone | M |
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
