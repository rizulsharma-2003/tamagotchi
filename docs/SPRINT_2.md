# Sprint 2: Windows matches the Mac, Android matches the iPhone

**Goal:** Every feature of the Mac app is built into Mochi for Windows, and the Android app closes its remaining gaps with Mochi Pocket for iPhone.

**Planned:** 2026-11-07.
**Code:** Windows is `flutter/apps/mochi_desktop`. Android is `flutter/apps/mochi_pocket`. Shared Dart packages are `mochi_link`, `mochi_art`, `mochi_ui` and `mochi_wire`.
**Reference:** the Mac app (`Sources/App`, `Sources/TamagotchiCore`) and the [README feature list](../README.md#features).

---

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

### G2 · Celebrations from real Claude events · M
Port the event classification behind celebrations (`commandKind`: build/test detection, long-turn detection, repeated tool errors).
- High five for a finished turn, victory dance for a long turn (only when both ends were seen live), **trophy for real build/test results**, detective mode → case closed, graduation for milestones.
- Never for simulated or late events.

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
| W11 | **Mochi talks**: speech bubbles for greetings, Claude events, petting and sleepy mumbles; chattiness quiet/normal/chatty (`Features/Speech`). Fresh lines come from Claude Haiku on Windows, not Apple Intelligence. | M |
| W12 | **Mochi grows up**: kitten → young → grown-up art over weeks of friendship (`Features/Growth`) | S (after G1) |
| W13 | **Progress**: friendship hearts and achievements UI | S |
| W14 | **Mini-games**: Catch the Treats (arrow keys or drag, combos, golden treats, high score) and rock-paper-scissors with Mochi and Patch (`Features/Games`) | M |
| W15 | **Focus buddy**: Pomodoro; Mochi naps while you focus, non-urgent sounds stay quiet, wake for a stretch (`Features/Focus`) | M |
| W16 | **Daily recap** at 18:00: sessions, turns, tool calls, test runs, errors, focus minutes and streak; save or copy as an image (`Features/Recap`) | M |
| W17 | **Share a clip**: a 5-second looping GIF drawn by the app, never a screen capture, saved to Downloads (`Features/Share`) | M |
| W18 | **Room makeover**: twelve furniture pieces unlocked by friendship and achievements; Decorate and drag (`Features/Room`) | M |
| W19 | **Explore the desktop**: drag Mochi off the taskbar and it walks along window tops, sits on the taskbar, climbs a screen edge and hops home; occasional spontaneous adventures (`Features/Adventure`). Uses `EnumWindows` rectangles only. | L |
| W20 | **Holidays, the rest**: seasonal treats, decorations on the taskbar strip, costumes on both characters (the art exists; the treats don't yet) | S |
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
| W29 | **Installer and updates**: MSIX or Inno Setup, Start menu entry, uninstall, auto-update, code signing (Store and Developer ID are still parked; see the Mochi Link plan, phase 7) | M |
| W30 | **Performance budget**: target the Mac's 1–2% CPU when calm and 3–4% when roaming (today about 8%), and idle RAM under 120 MB | M |
| W31 | **Native ARM64 build** when the Flutter version we move to supports it (today Mochi runs as x64 under emulation on ARM PCs) | S (an upgrade spike) |

---

## Android backlog (iPhone → Android)

| # | Feature (iPhone reference) | Android approach | Size |
|---|---|---|---|
| A1 | **Live Activity equivalent**: Mochi on the Lock Screen and status bar while Claude works, lighting up when Claude needs you and celebrating when done | An ongoing notification (Android 16 *Live Updates* / progress-style, falling back to a standard ongoing notification), updated by FCM data messages. **The relay needs Android `liveActivity` delivery through FCM**; today Live Activity frames go to APNs only. | L |
| A2 | **Home-screen widget**: "Mochi & Claude" with Waiting for you, like the iPhone Lock Screen widget (`iOS/MochiWidgets`) | An AppWidget (Glance), updated from the app and FCM | M |
| A3 | **Hold to talk**: press and hold Mochi, Mochi listens, and the request runs on the computer (`TalkModel`, `PhoneListener`) | Android on-device `SpeechRecognizer` (offline when available) | M |
| A4 | **"Hey Google" instead of Siri**: "What's waiting on Mochi?" and similar phrases (`MochiIntents`) | App Actions / Shortcuts (capabilities.xml), a Quick Settings tile and app shortcuts. Read the answer in Mochi's voice. | M |
| A5 | **Full pet simulation in the room**: the iPhone runs `CompanionWorld`; Android plays recorded poses | Use G1 `mochi_world` | M (after G1) |
| A6 | **Updates history**: a week of history grouped by day, like the iPhone (today: waiting and done only) | S |
| A7 | **Mochi Cloud on the phone**: "Check now" through Mochi Cloud when the computer is off, and **reply drafts** | Read the agent state from the room; trigger the cloud check like the iPhone | M |
| A8 | **Notification actions**: Reply to a session from the notification, Join, Mark done, Approve/Decline. Match the iPhone's categories (`PhoneNotifications`). | Notification actions with RemoteInput | M |
| A9 | **Mochi's voice upgrade**: a licence-clean neural voice (Kokoro with a non-GPL phonemiser) | Spike: research only | S |
| A10 | **Play Store release**: listing, privacy form, signing (parked with phase 7 until the user unparks it) | M |

---

## Suggested order

1. **Week 1, quick wins:** W1, W2, W3, W4, W5, W6, W10, A6, A8.
2. **Week 2, Claude power:** W8, then W9 (with the safety review). In parallel: A1 (with relay support) and A3.
3. **Weeks 3–4, Mochi's life:** G1, G2, then W11–W18 and A5.
4. **Week 5, agent and voice:** W23, W24, W25, A4, A7.
5. **Week 6, polish:** W7, W19–W22, W26–W31, A2.

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
