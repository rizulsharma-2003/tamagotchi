# Sprint 3: Mochi in your pocket

**Starts:** after Sprint 2 ([docs/SPRINT_2.md](SPRINT_2.md)).
**Planned:** 2026-11-07, from the user's direction.

## The goal (in the user's words)
> When a user uses it, they should use their computer less. Everything should be in their pocket, so they can work from anywhere, and Mochi also acts as their personal assistant.

That gives three tests for every Sprint 3 item:
1. **Pocket-first:** can you do it from the phone, comfortably, with one thumb, without walking back to the computer?
2. **Assistant:** does Mochi take work off your plate (prepare, remind, draft, watch), not just show information?
3. **Mochi:** does it feel like Mochi (its personality, its art), on every device?

The computer (Mac or Windows PC) becomes the engine that runs Claude Code and the agent. The phone becomes the cockpit.

---

## Epic A: Redesign the phone apps around "work from anywhere" (iPhone and Android)
A lot is coming to the phone apps, and today's single scrolling home screen won't hold it. Redesign both apps with **the same information architecture**: iPhone in SwiftUI, Android in Flutter, both on the clay design system and Nunito.

### A1 · Research and structure · M
- **Jobs to be done.** For each of these, ask how fast it is from a cold phone:
  - check on Claude
  - approve
  - reply
  - start a task
  - triage mail and calendar
  - ask Mochi anything
  - control the computer
  - glance at today
  - play with Mochi
- **Proposed tabs** (to validate with wireframes):
  - **Today:** Mochi's briefing, next meeting with Join, what's waiting, Claude at a glance
  - **Claude:** live sessions per computer, progress, approvals, replies, diffs, start a task
  - **Inbox:** the agent's mail, calendar and Notion items, drafts, follow-ups, done
  - **Ask:** a conversation with Mochi, voice-first, with history
  - **Mochi:** the room, Pet/Play/Treat, friendship, games
- **Global elements:** an **Ask Mochi** button reachable from every screen, a computer switcher (Mac / PC, from the multi-host design), and an offline/queued indicator.
- **Deliverables:** wireframes, then a clickable prototype (a published Artifact), then a quick usability pass with the user, then the final spec.

### A2 · Design system v2 · M
Extend Theme.swift / mochi_ui with:
- **Components:** cards for sessions, approvals, diffs, mail, meetings and tasks; bottom sheets; swipe actions (done, snooze, approve); haptics; skeleton loading; empty states with Mochi art.
- **Motion:** the Mac's smoothness, with Reduce Motion respected.
- **Accessibility:** large text up to 2×, VoiceOver and TalkBack, contrast at least 4.5:1, 44pt / 48dp targets.
- **Process:** use the UI/UX Pro Max skill, as in the last redesign.

### A3 · Build the new iPhone app · L
### A4 · Build the new Android app · L
They share the information architecture, the copy and the personality. Each matches its platform's conventions: navigation, back gesture, share sheets.

### A5 · Glanceable and hands-free everywhere · M
- **iPhone:**
  - Lock Screen and Home Screen widgets: Claude status, approvals, next meeting
  - Control Center controls and the Action button: Ask Mochi, Approve all safe, Pause Mochi
  - Live Activity v2: per computer, with approval buttons
  - Siri phrases for the top jobs
- **Android:**
  - Home-screen widgets
  - Quick Settings tiles
  - an ongoing Live-Update notification (Sprint 2's A1)
  - "Hey Google" App Actions
  - notification actions everywhere (Sprint 2's A8)
- **Optional:** CarPlay / Android Auto voice briefing ("what's waiting?", "approve?").

---

## Epic B: Run your computer and Claude from the phone
| # | Feature | Notes | Size |
|---|---|---|---|
| B1 | **Approve Claude's permission prompts from the phone** (idea 1) | Claude Code's PermissionRequest hook goes to the host, then a sealed push to the phone; Allow / Deny comes back. Default is deny on timeout. Face ID / fingerprint for risky tools. Works on Mac, PC, iPhone and Android. | M |
| B2 | **Start a Claude task from the phone:** "Mochi, fix the failing test in web" | The host starts a Claude Code session in that repo (chosen from the computer's recent projects) and streams progress back. Approvals go through B1. It ends with a summary and a diff. | L |
| B3 | **Live progress and diffs on the phone** | Tool-by-tool progress, files changed, and a readable diff viewer: Approve, "Ask Claude to change…", Commit & push, Open PR (Claude does the git work on the computer) | L |
| B4 | **Stop / interrupt / redirect** a running session from the phone | M |
| B5 | **Keep the computer awake** while Claude runs, and warn "your Mac is about to sleep with Claude running" | Mac: caffeinate / IOPMAssertion. Windows: SetThreadExecutionState. | S |
| B6 | **Remote quick actions** on the computer: lock, sleep, open a URL there, play/pause, mute, join the meeting on the computer | An allow-list with confirmation cards (as Ask Mochi already does) | M |
| B7 | **Clipboard bridge:** send text or links between phone and computer, end-to-end encrypted | S |
| B8 | **File drop:** send a photo or file from the phone to the computer's Downloads, or straight to a Claude session ("add this screenshot to the bug") | Sealed upload through the relay, size limit | M |
| B9 | **Peek at a window:** "show me what's on my screen", one window, per request, previewed first | The same rules as Sprint 2's X17 | M |
| B10 | **Queued while away:** anything sent while the computer sleeps runs when it wakes, with a clear status | S |

## Epic C: Mochi as your personal assistant
| # | Feature | Notes | Size |
|---|---|---|---|
| C1 | **Daily stand-up writer** (idea 5): yesterday and today, from real sessions and the calendar; copy to Slack | M |
| C2 | **Meeting assistant:** before a meeting, who's coming, last emails with them, related Notion docs; after it, a follow-up draft | Builds on the agent's connectors | M |
| C3 | **Follow-ups:** "remind me if Priya doesn't reply by Friday" | The agent watches the thread and nudges | M |
| C4 | **Voice notes into tasks:** dictate an idea; Mochi turns it into a Claude task, a Notion item or a reminder | M |
| C5 | **Smart digest:** low-priority items bundled at times you choose; urgent things straight away | S |
| C6 | **Away mode:** Mochi drafts replies for your approval, keeps Claude tasks going, and interrupts only for what matters | M |
| C7 | **Context modes:** at desk (the phone stays quiet; the computer has you), commute (voice-first, short), focus, bedtime (idea 12) | Uses the computer's activity signal (Sprint 2 W2) | M |
| C8 | **Rubber-duck mode** (idea 11): talk through a bug; Mochi asks good questions and hands a summary to a Claude session | M |
| C9 | **One "Today" list across all devices:** what's waiting, what Claude finished, your follow-ups | S |

## Epic D: Mochi's personality
Mochi should sound like **one character** everywhere: speech bubbles, notifications, Ask Mochi replies, Siri and Google Assistant answers, the agent's briefings, read-aloud, and empty states.

### D1 · The personality bible · S
Write `docs/MOCHI_VOICE.md` covering:
- **Traits,** proposed: warm, playful, brief, quietly proud of you, curious, never smug, never guilt-trips.
- **Voice rules:** sentence length, words Mochi uses and avoids, emoji policy, how it addresses you (your name, optional), humour level by context (playful when things are good, calm and plain when something failed or is urgent).
- **Moods:** sleepy, excited, focused and worried change the tone, not the facts.
- **Do and don't examples** for each surface.
- **Patch,** for contrast: a quiet, nerdy, focused co-worker who speaks rarely.
- **Never:** pretend to be human, make up facts, hide failures, or nag.

To agree with the user before D2–D4.

### D2 · The phrasebook · M
Every static line across Mac, Windows, iPhone and Android, rewritten to the bible and shared as a single file of variants. That gives the same lines everywhere, with random-but-seeded variety so Mochi doesn't repeat itself.

### D3 · Claude-written lines in Mochi's voice · M
- **Where:** one shared system-prompt fragment, from the bible, used by every Claude-generated text: Ask Mochi, turn summaries, the agent's briefings, stand-ups, drafts (drafts stay in *your* voice, not Mochi's).
- **Checks:** a few eval cases per surface.

### D4 · Personality settings · S
- **Chattiness:** quiet / normal / chatty (the Mac already has this).
- **How Mochi addresses you.**
- **"Mochi's mood shows in its voice":** on or off.

---

## Epic E: The 14 ideas from Sprint 2 planning
| # | Idea | Platforms | Where it lands |
|---|---|---|---|
| 1 | Approve Claude's permission prompts from the phone | All | **B1** |
| 2 | Claude cost and usage meter (per session and project; gentle warnings) | All | E2 |
| 3 | "Claude is stuck" nudges (waiting for permission too long, long-running command, repeated error) | All | E3 |
| 4 | CI buddy (GitHub Actions for Claude's branch; celebrate or worry; open the failing run) | All | E4 |
| 5 | Daily stand-up writer | All | **C1** |
| 6 | Session timeline (scrub today's turns, tools, errors, wins) | All | E6 |
| 7 | Repo cards (repo, branch, uncommitted changes; Open in VS Code / terminal) | All | E7 |
| 8 | Taskbar progress on Mochi's taskbar button (Windows); Dock badge (Mac) | Windows, Mac | E8 |
| 9 | Ask Mochi from the PowerToys Command Palette / Run, and from Raycast / Spotlight on the Mac | Windows, Mac | E9 |
| 10 | Live wallpaper (Mochi's room as the desktop) | Windows, Mac | E10 |
| 11 | Rubber-duck mode | All | **C8** |
| 12 | Bedtime mode | All | **C7** |
| 13 | Wear OS / Apple Watch: glance and approve from the wrist | Watches | E13 |
| 14 | Stream Deck buttons (Approve, Ask Mochi, Pause, Open session) | Mac, Windows | E14 |

---

## Suggested order
1. **D1** (the personality bible) and **A1** (research and structure). Both shape everything after them. Review both with the user.
2. **B1**, approvals from the phone, the biggest "work from anywhere" win. Ship it on today's apps first.
3. **A2–A4,** the redesign, built around B1, C9 and D2.
4. **B2–B4,** running Claude from the phone. **E3** and **E7** fit naturally here.
5. **C1–C7,** the assistant features, plus **E2**, **E4** and **E6**.
6. **A5** (widgets and hands-free), then **B5–B10**.
7. The platform extras: **E8–E10**, **E13**, **E14**.

## Principles that still hold
- **Privacy:** end-to-end encrypted through the user's own relay. The relay never reads content. Explicit approval for anything that acts on the computer or sends on your behalf.
- **Safety:**
  - Default deny for approvals.
  - Biometric confirmation for risky actions.
  - An allow-list for remote actions.
  - Nothing is ever sent or deleted without a visible card.
- **Mac remains the reference.** Every new feature lands on the Mac and Windows hosts together, and on both phones together.
