# Privacy

MacTamagotchi is local-only unless you turn something on. There is no account, analytics, or network listener.
The app's own traffic is two things you start yourself:

- **Claude Code.** When you ask Mochi for something it can't do on the spot, the request goes to Claude through
  your own Claude Code login (see *Ask Mochi* below); so do Claude's summaries and the agent's checks, if you
  turn them on.
- **Your Mochi Link relay**, once you pair a phone: everything between this Mac and your phones goes through it,
  end-to-end encrypted (see *Mochi Link* below). Nothing goes through iCloud, and this Mac never talks to Apple's
  push service itself.

## Mochi Link (your phones)

Your Mac, your phones (Mochi Pocket on the iPhone, Mochi on Android) and Mochi Cloud talk only through Mochi
Link: one small relay that you run (a Cloudflare Worker, `mochi-link.spike01.workers.dev` today). Until you pair a
phone in Settings › iPhone › Mochi Link, nothing from this Mac goes to it, and Mochi Pocket works on its own.

- **Pairing:** the Mac makes a room key and shows it in a QR code; the phone scans it. The key stays in each
  device's Keychain and never goes to the relay.
- **What the relay sees:** room and device ids, roles and platforms, your phones' push addresses, key names
  (`command`, `look`, …), message sizes and times.
- **What it never sees:** everything else is sealed with AES-256-GCM under the room key: what you said, Mochi's
  answers, Claude's summaries, project and file names, mail, calendar and task details, the pet's look.
- **Pushes:** the relay holds the push keys and wakes your phones through Apple's push service (iPhone) or
  Firebase Cloud Messaging (Android). A notification only says "Mochi has news" until the phone opens its sealed
  text. A Live Activity's title and detail are sealed the same way; its phase, timer and pose number are readable
  by the relay and Apple.
- **What it keeps:** the latest value of each shared item, and messages until they're delivered or expire
  (commands and replies after 10 minutes). Rooms nobody uses for 90 days delete themselves; *Unpair This Mac*
  deletes the room at once.

## What reaches the app

Claude Code passes each hook a JSON payload on stdin. The helper (`mactamagotchi-hook`) runs inside that
hook process and forwards only this allow-list over a private Unix socket:

| Field | Example | Notes |
|---|---|---|
| event name | `PreToolUse` | |
| session id | `21d77d34-…` | Claude Code's opaque id |
| project name | `InsideEdge` | last path component of the project folder |
| project key | `78f10b52ef80` | one-way hash of the folder path, to tell projects apart |
| project path | `/Users/you/Code/InsideEdge` | kept **in memory only** for “Reveal Project”; stored only if you opt in |
| tool name, tool-use id, tool category | `Bash`, `toolu_…`, `shell` | |
| exit code | `1` | parsed from a leading `Exit code N`; the error text is dropped |
| command kind | `test` / `build` + trustworthy? | the command itself is never sent |
| notification type and short text | `permission_prompt`, “Claude needs your permission to use Bash” | text can be turned off |
| subagent type, session source/end reason, API error type, model, permission mode | `Explore`, `startup`, `rate_limit` | |
| batch size and tool names | `3`, `Read,Grep` | |
| host app | `com.microsoft.VSCode` | bundle identifier of the editor or terminal the session runs in, so Ask Mochi can bring that window forward |

**Never sent**: prompts, tool inputs, file contents, command output, error messages, transcript paths, MCP
arguments, environment variables. Claude's closing message and the names of changed files are sent only while
you share summaries with a paired iPhone (below, off by default).

| Only while you share summaries | Example | Notes |
|---|---|---|
| Claude's last message of a turn (`last_assistant_message` on Stop) | “Fixed the login bug…” | up to 4,000 characters; summarized in memory, never journaled or spooled |
| name of a file an editing tool changed (PostToolUse of Edit, Write, MultiEdit, NotebookEdit) | `Auth.swift` | the name only, never its folder or contents |

The hook helper includes these only while `share-summaries` exists in MacTamagotchi's private folder; the
app creates it while the setting is on and a phone is paired, and deletes it when either stops.

## What is kept

| Data | Where | Retention |
|---|---|---|
| Sanitized events (the table above, minus paths) | `history.jsonl` | 7 days by default (off / 1 / 7 / 30), at most 2,000 events |
| Events received while the app was closed | `spool/pending.jsonl` | until next launch, max 512 KB |
| Settings | `settings.json` | |
| Friendship points, achievement dates, hashed project keys | `progress.json` | until you reset |
| Backups of `~/.claude/settings.json` | `Backups/` | last 20 |

Everything is in `~/Library/Application Support/MacTamagotchi/` (mode 0700, files 0600). Settings ›
Privacy lets you clear history, stop keeping it, opt in to storing project paths, or drop notification text.
Simulated events are never written to history.

## Feature-specific data

| Feature | What it uses | Notes |
|---|---|---|
| Speech bubbles | the kind of moment (e.g. "Claude finished a task") and the two names | Lines are hand-written. With *Fresh lines from Apple Intelligence* on (Settings › Fun), the app asks the **on-device** model for a few new lines every couple of hours. The prompt holds only the kind of moment and the names — never projects, files, commands or anything typed — and nothing leaves the Mac. |
| Desktop widget | `Widget/status.json` and `Widget/scene.png` in the app folder | The kind of work ("Editing files", "Claude needs you"), the pet's name and friendship level, and a picture of the scene drawn by the app itself. No project names. The widget is sandboxed and may read only that folder. |
| Trackpad purr | haptic feedback while you press and hold on Mochi | Nothing is recorded. |
| Desktop adventures | other windows' frames (position, size, layer, transparency, owning process id) | Read about 3 times a second **only while Mochi is out exploring**, to find window tops to walk on. Window titles and contents are never read. |
| Picking Mochi up from the menu bar | the pointer position near the menu bar | Polled only while the menu-bar overlay is visible (4 Hz, 15 Hz near the bar) so the overlay can accept a click or drag exactly over Mochi and stay click-through everywhere else. Never stored. |
| Focus buddy | completed focus blocks (date and minutes) in `focus-log.json` | Follows your history retention; cleared with Clear History. |
| Holidays | your birthday month and day, if you enter it | In `settings.json`. |
| Ask Mochi: typed requests | what you type, plus one line of context: the time, the front app's name, and the names and states of your Claude sessions | Quick commands (music, volume, focus, "open Slack", "what are my Claudes doing") run on the Mac and send nothing. Everything else goes to a helper Claude session (`claude -p --name mochi`, your login, Haiku by default). That session loads none of your settings or hooks, can use only Mochi's tools, web search and Claude Code's session messaging, is not saved to disk (`--no-session-persistence`) and stops after 10 quiet minutes. The conversation lives in memory only. |
| Ask Mochi: voice | the microphone, **only while you hold the shortcut** | Speech is turned into text on this Mac (Apple's SpeechAnalyzer). Audio is never stored or sent; only the text is used, like a typed request. |
| Ask Mochi: prompts to your Claude sessions | the message the helper wants to send | Shown on a card and sent only when you press Send. Delivery uses Claude Code's own session messaging over a local socket (never through a server). It arrives as "Message from @mochi", can't approve anything for you, and that session's permission prompts still apply. MacTamagotchi never types into windows. |
| Mochi on your iPhone (off by default) | the phase ("working", "needs you", "finished"), a title, a timer start and a tool count; project names only if you allow them | Sent through Mochi Link (above) to the Mochi Pocket app on your paired iPhone, with the title and detail (where project names and the tool count appear) sealed so only your phones can read them. The relay holds the push key and the iPhone's push addresses; this Mac holds neither. No prompts, files, commands or session contents. |
| Your Mac's rhythm (Naps) | every 5 seconds: seconds since the last keyboard, mouse or trackpad input (never which keys or where), whether the displays or the Mac sleep or another user switched in, whether something keeps the screen on (a public power assertion, such as a video or call), and processor load | Used to put Mochi to sleep while the Mac rests and wake it when you're back. Nothing is stored. With a paired phone, only "resting: yes/no" is shared, in `claude` through Mochi Link (sealed). Turn it off in Settings › Mochi › Naps. |
| Mochi's room on the iPhone | the pet's look (names, colours, room), Claude's phase and tool category, and pet/play/treat taps | Shared between your Mac and paired phones through Mochi Link, end-to-end encrypted, so both rooms match. No projects, files or commands. |
| Claude's summaries on the iPhone (off by default) | Claude's closing message for each finished turn, the names of the files it changed, and your sessions' project names and phases | The message is summarized on this Mac by a one-off `claude -p` (Haiku, your login, no tools, none of your settings, not saved). The summary, project name and file names go to your phones as an end-to-end encrypted notification through Mochi Link, and the session list as the link's `sessions` item (sealed; only the latest is kept). While no phone is paired, Claude's message and file names aren't collected at all. The original message stays in memory and is gone when the app quits. A reply you send from the notification or a session card goes to that session like an Ask Mochi message; if Mochi found that project's only live session and kept your words, it is sent without a second approval. |
| Mochi's agent (off by default) | new unread mail in your inbox, coming events on your primary calendar, open Notion tasks assigned to you | Every few minutes (never in its quiet hours) a one-off `claude -p` (Haiku, your Claude login, none of your settings, not saved) reads them through the Gmail, Google Calendar and Notion connectors in your Claude account. `--permission-mode dontAsk` with a list of read-only tools means it can search and read but never send, edit or delete. The one exception: when you mark an email done (and keep *Mark the email read in Gmail* on), a separate run allowed only Gmail's `unlabel_thread` removes the UNREAD label from that thread. Mochi Cloud's "Draft reply" (from Mochi Pocket) can create a draft in Gmail Drafts for that one thread; it never sends. Any API key in the environment is removed first, so the run always uses your subscription. Claude returns a short digest (sender, subject, a gist, event titles and times, task titles); Mochi says the important part, and with *On my iPhone* on, sends it to your paired phones as an end-to-end encrypted notification through Mochi Link. `agent.json` in MacTamagotchi's private folder keeps what Mochi told you and the ids it has seen, for two weeks. Your mail and pages are never stored. |
| Talking to Mochi on the iPhone | the microphone **only while you press and hold Mochi**; the words you said | Speech is turned into text on the iPhone. The text, Mochi's short answer and any approval request travel between your iPhone and Mac through Mochi Link, end-to-end encrypted; the relay holds a message only until it's delivered (at most 10 minutes). Then the request is handled like Ask Mochi on the Mac (see above). |
| Ask Mochi: Mac control | running apps' names; with Accessibility allowed, window titles | Titles are matched on the Mac to find the window you mean and are never sent to Claude. App names are sent only when the helper asks which apps are running. Accessibility is optional and is needed only for music keys and picking a specific window. |

## What MacTamagotchi never does

- Monitor keystrokes, read the clipboard or capture the screen. The microphone is used only while you hold
  the Ask Mochi shortcut, and audio is never kept.
- Inspect your documents or source code.
- Upload anything you haven't turned on. The app's only traffic of its own is your Mochi Link relay, once you
  pair a phone (Settings › iPhone), and everything it carries is end-to-end encrypted. Ask Mochi requests and the
  agent's checks (Settings › Agent, off by default) travel through your Claude Code; the hook helper has no
  network code.
- Use iCloud, or hold a push key.
- Open a network port. The sockets are in a private directory, mode 0600, and every connection's peer UID
  is checked; Mochi's tool socket also requires a one-time token that changes with every helper session.
- Change Claude Code settings without an explicit Connect or Disconnect (each with a preview and a backup).

The global shortcuts (⌃⌥⌘P and the Ask Mochi shortcut, ⌥Space by default) use Carbon hot keys, which only report that one key combination and need no
Accessibility permission. Native notifications are requested only if you turn banners on.
