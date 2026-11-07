# Sprint 3 · A1: the phone app's structure

> **DRAFT for review, 2026-11-08.** This is a proposal, and nothing in the apps has changed. It covers A1 in
> [SPRINT_3.md](SPRINT_3.md) (Epic A): the jobs, the tabs, and what moves where. The words in the prototype follow
> [MOCHI_VOICE.md](MOCHI_VOICE.md), which is also a draft.
>
> **Clickable prototype:** `phone-prototype.html`, one self-contained file, kept out of the repo in the session
> scratchpad at
> `docs/prototypes/sprint3-phone-prototype.html (open it in a browser)`
> (to be published as an Artifact). Turn on **Show design notes** for 24 numbered callouts that explain each
> decision. All content is sample data from the apps' demo content.

## 1. How to review it (five minutes)
1. Open the prototype. A notification drops in: Claude in mac-Tamagotchi wants to run `swift test`.
2. **Allow** or **Deny** it. About five seconds later a riskier request arrives (`git push`), which needs Face ID.
3. Open **mochi-link** in the Claude tab, then a changed file (the diff stub).
4. In **Inbox**, swipe a row left (or tap it) for Done and Snooze, and look at the Drafts section.
5. **Press and hold Ask Mochi** on any screen and let go to send. On the Ask tab the same button is the mic.
6. Tap the **Mac** chip, try a remote action, then turn on "Pretend the Mac is asleep" to see the queued state.
7. Read section 5 below and answer the open questions.

---

## 2. Jobs to be done, and how fast they are from a cold phone

**How the taps are counted.** A cold phone is locked, with Mochi not open. Unlocking with Face ID or a fingerprint
counts as 0. Opening the app from the Home Screen is 1 tap; a hold counts as 1; typing isn't counted but is noted.
The fastest route is a widget, the Lock Screen, a notification or a voice assistant. Routes marked A5 are planned
later in Sprint 3.

| # | Job | Today's app (iPhone; Android where it differs) | Proposed | Fastest route |
|---|---|---|---|---|
| 1 | **Glance at today** | 1 tap, then scroll past the header and the room to "Waiting for you" | **1**: the briefing is the first thing on Today | 0: the Lock Screen "Waiting" widget (iPhone today; A5 adds the next meeting and Claude) |
| 2 | **Check on Claude** | 1, then scroll below the room and the waiting card to "Claude on your Mac" | **1** for the glance on Today; **2** for a session's steps | 0: Live Activity (iPhone); the ongoing notification (Android, A5) |
| 3 | **Approve** Claude's permission prompt | **Not possible:** walk back to the computer. (Only Ask Mochi's own "Send to Claude?" can be approved on the phone.) | **2**: open, then Allow on Today's card (+ Face ID for risky tools) | iPhone notification: 2 (hold, then Allow). Android: 1 (the Allow button). Live Activity v2: 1 |
| 4a | **Reply to Claude** | Notification: 2 + typing. App: 1, scroll, Reply (2), type, Send (3) | **3**: open, the session on Today, then a suggested reply (no typing) or type + Send | Notification Reply: 2 + typing |
| 4b | **Reply to an email** | 1, See all (2), swipe or hold for "Draft a reply…" (3), Draft It (4) | **4**: open, Inbox, **Draft reply** (now a visible button), Draft it | Voice: open, hold Ask Mochi, "Draft a reply to Priya saying…": 2 |
| 5 | **Start a task** | **Not possible:** Ask Mochi can only message a session that's already running | **4**: open, Claude, Start a task, pick a project + type, Start. By voice: **2** | Siri / "Hey Google": "Start a Claude task in Mochi" (A5): 0 |
| 6 | **Triage mail and calendar** | 1, See all (2), then a swipe per item (or ✓ on the card's top 4) | **2**, then 1 per item (swipe or tap + Done); or ✓ on Today's top 3 | Notification "Mark done": 1–2 |
| 7 | **Ask Mochi anything** | iPhone: 1, then hold Mochi in the room (2). Android: 1, Type (2), type, Send (3) | **2**: open, then hold Ask Mochi **on any screen** | Siri, the Action button, a Control Center control (A5): 0–1 |
| 8 | **Control the computer** | Through Ask Mochi: 1, Type (2), "pause the music", Send (3) | **3**: open, the Mac chip, the action (+1 to confirm Lock or Sleep). By voice: 2 | A Control Center control or Quick Settings tile (A5): 1 |
| 9 | **Play with Mochi** | **2**: open, Pet | **3**: open, Mochi, Pet. Or **2**: tap Mochi on Today's briefing to pet | |

**In short:** approving and starting a task become possible from the phone (both are new). Glancing, checking on
Claude and asking Mochi get faster or stay the same. Playing costs one more tap, on purpose: it's the least urgent
job, so the room moves off the front page.

---

## 3. The tabs, and why

| Tab | What's in it | Why it earns a tab | Sprint 3 items |
|---|---|---|---|
| **Today** | Mochi's briefing (Read aloud, who checked); a pending approval when there is one; the next meeting with **Join** and **Brief me**; the top 3 things waiting, each with a done circle; Claude at a glance | Glancing is the most common cold-phone job, so Today is the landing tab. It answers "what needs me?" in one screen. | C1 stand-up (later), C2, C9, D3 |
| **Claude** | Approvals at the top; sessions grouped by computer ("On your Mac"); live progress; **Start a task**; session detail (what it's doing, steps, files changed → diff, suggested replies, Stop, Commit & push) | The highest-value "work from anywhere" job, and the home of Epic B | B1–B4, B10, E2, E3, E6, E7 |
| **Inbox** | One list for mail, meetings and Notion: Needs you (swipe for Done and Snooze; Join and Draft reply as visible buttons), the quieter mail bundled into one row, Drafts, Follow-ups, Done today | Triage needs a full-screen list. Today's "See all" sheet becomes a tab. | C3, C5, C6, C9 |
| **Ask** | A conversation with Mochi: voice first, with history, and approvals inline ("Send to Claude?") | Voice requests and their follow-ups need a place that keeps the history | C4, C8, B6 by voice |
| **Mochi** | The room (with the season's decor), Pet / Play / Treat, games, Focus, Your day, Mochi's voice settings (D4), and the Settings button | Mochi stays one tap away, but no longer stands between you and your work | D4 |

**Order.** Work comes first, from the most glanced at (Today) to the most playful (Mochi). The order is the same on
iPhone and Android.

**Global elements, on every screen:**
- **Ask Mochi button.** A tap opens Ask as a sheet over the current screen; a hold talks straight away (today's
  "hold Mochi to talk", now available everywhere). On the Ask tab it turns into the mic.
- **The computer chip** ("Mac"). It is the Mac / PC switcher from the multi-host design, but **shows "Mac" only,
  because multi-host is parked** ([MULTI_HOST_PLAN.md](MULTI_HOST_PLAN.md)). Its sheet shows the PC as parked. It
  also opens the Mac's remote actions (B5 keep awake, B6 lock / sleep / play-pause / mute, B7 clipboard, B8 file).
- **Offline and queued indicator.** The chip says "Mac · asleep", and a strip under the status bar says what's
  queued and that it runs when the Mac wakes (B10).
- **Toasts** confirm what was *sent*, with Undo where it's possible.

**Platform conventions** (A3 and A4 keep the structure and follow each platform's own conventions):

| | iPhone (SwiftUI) | Android (Flutter, Material 3) |
|---|---|---|
| Tabs | `TabView` with the system tab bar | `NavigationBar` |
| Ask Mochi | A custom floating button, or the tab bar's own trailing button or bottom accessory (to check in A2) | Extended FAB (native) |
| Back from a session | Edge swipe; tapping the Claude tab again pops to the list | Predictive back |
| Sheets | `.sheet` with detents | `ModalBottomSheet` |
| Swipe rows | `swipeActions` + accessibility actions | `Dismissible` + visible buttons + TalkBack actions |
| Notification approve | Long-press, then Allow / Deny (Face ID for risky tools) | Allow / Deny buttons (fingerprint for risky tools) |

---

## 4. What moves from today's app, and where

Today's home screen is one scrolling page (`iOS/MochiPocket/ContentView.swift`; Android
`flutter/apps/mochi_pocket/lib/src/screens/home_screen.dart`) plus three sheets.

| Today (iPhone file · Android file) | Moves to |
|---|---|
| Header: Mochi's name, "and Patch, from your Mac", friendship (`ContentView` · `home_screen.dart`) | **Mochi** tab header; "from your Mac" becomes the **computer chip** on every screen |
| The room, and tap-to-pet (`RoomView.swift` · `scene/room_view.dart`) | **Mochi** tab. Today's briefing avatar can still be petted. |
| Pet / Play / Treat | **Mochi** tab, unchanged |
| Type + the typing field; hold Mochi to talk (iPhone) | **Ask** tab and the global **Ask Mochi** button (hold to talk on Android too) |
| "Send to Claude?" approval card | Inline in the **Ask** conversation (as on the Mac) |
| *New:* Claude's permission prompts (B1) | Top of the **Claude** tab, mirrored on **Today** while one is pending |
| "Waiting for you" card: top 4, Read aloud, Check now, Checked by (`AgentCard.swift` · `widgets/agent_card.dart`) | **Today**: the briefing (Read aloud, Checked by) + the top 3. Check now becomes pull-to-refresh on Today and Inbox. |
| "See all" sheet: waiting + 7 days by day, Mark all done, swipe Done (`UpdatesView.swift` · `screens/updates_screen.dart`) | **Inbox**: Needs you, Done today, and the week's history at the bottom |
| Draft reply sheet (`DraftReplySheet`) | **Inbox**: the row's Draft reply button opens the same sheet; ready drafts are listed under Drafts |
| "Claude on your Mac" session cards with Reply and changed files (`SessionCard.swift` · `widgets/session_card.dart`) | **Claude** tab list + session detail; one line per session on **Today** |
| "Recently" (what you asked Mochi) | **Ask** history |
| Settings sheet: Live Activity, Mochi's voice, Siri, Claude's summaries, notifications, Mochi Link (`PocketSettingsView.swift` · `screens/settings_screen.dart`) | **Settings**, opened from the **Mochi** tab. Mochi Link's status also shows in the computer chip's sheet. |
| Pairing (`screens/pairing_screen.dart`) | Unchanged: first run, and Settings › Mochi Link |
| Live Activity, the Lock Screen widget, Siri intents, notification actions | Unchanged, but they open the new tabs (Waiting widget → Inbox; Live Activity → that Claude session; approval notification → its card) |

---

## 5. Open questions

1. **The landing tab.** Always Today, or whichever tab you used last?
2. **Approvals on Today.** Should a pending approval also sit at the top of Today (as in the prototype), or only in
   the Claude tab and the notification?
3. **Ask Mochi on the iPhone.** A custom floating button (the prototype), or the system tab bar's trailing button or
   bottom accessory, which is more native but less "Mochi"?
4. **Does Ask need a tab** when the button is everywhere? It keeps the history and longer voice conversations. The
   alternative is 4 tabs, with the history inside the Ask sheet.
5. **Claude's finished work in Inbox?** C9 asks for "one Today list" of what's waiting, what Claude finished and your
   follow-ups. Should Claude's results join Inbox, or stay in the Claude tab?
6. **Snooze.** A fixed time ("until 6 PM") or a quick picker (later today / tonight / tomorrow morning)?
7. **Settings.** In the Mochi tab (the prototype), or behind a button in every header?
8. **Remote actions.** In the computer chip's sheet (the prototype), or as a "Your Mac" section in the Claude tab?
9. **The room while the Mac sleeps.** Should Mochi nap on the phone too, as a quiet "your Mac is asleep" signal?
10. **Left-handed use.** Mirror the Ask Mochi button to the left (a setting)?
11. **Names.** "Inbox", or "Waiting" (today's word)? "Claude", or "Sessions"?
12. **The usability pass.** Five timed tasks to try with you: approve, reply to Claude, start a task, triage 3 items,
    and ask "what's waiting?". Any to add?

---

## 6. Next steps
- **A1:** your review of this draft and the prototype, then a quick usability pass, then the final spec.
- **A2, the design system v2:** the components this structure needs, all in the prototype: the approval card, the
  session row with live progress, the diff viewer, the swipe row with visible actions, the bundled row, the draft
  card, chat bubbles with an inline approval, the computer chip and its sheet, the offline / queued strip, a toast
  with Undo, and empty states with Mochi's art.
- **Not covered by the prototype:** the Settings screens, pairing, widgets and the Live Activity, iPad and landscape,
  2× text size, and VoiceOver / TalkBack passes. Those come in A2.
