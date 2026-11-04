# Claude Code integration

MacTamagotchi uses only Claude Code's documented [hooks](https://code.claude.com/docs/en/hooks).
It never scrapes the terminal, reads the screen, injects input or uses private APIs.

## Verified environment

Developed and verified against **Claude Code 2.1.309** (CLI) on macOS 27 with Xcode 27 / Swift 6.4.
All 13 events below were detected in that version by inspecting the installed CLI.

## Events

| Hook event | Purpose | Normalized kind |
|---|---|---|
| `SessionStart` | session started / resumed / cleared / compacted / forked (`source`) | `sessionStarted` (compaction is not a new session) |
| `UserPromptSubmit` | a prompt was submitted — **the prompt text is discarded** | `promptSubmitted` |
| `PreToolUse` | a tool is about to run (`tool_name`, `tool_use_id`) | `toolStarting` |
| `PostToolUse` | a tool finished successfully | `toolSucceeded` |
| `PostToolUseFailure` | a tool reported an error — only a leading `Exit code N` is kept | `toolFailed` |
| `PostToolBatch` | a batch of parallel tool calls resolved (count + tool names) | `toolBatchFinished` |
| `PermissionRequest` | Claude asks permission to use a tool | `permissionRequested` |
| `Notification` | `permission_prompt`, `idle_prompt`, `elicitation_*`, `agent_needs_input` → attention; others informational | `attentionNeeded` / `notification` |
| `SubagentStart` / `SubagentStop` | subagents (`agent_type`, `agent_id`) | `subagentStarted` / `subagentStopped` |
| `Stop` | Claude finished responding to the turn | `turnCompleted` |
| `StopFailure` | the turn ended with an API error (`error` type only) | `turnFailed` |
| `SessionEnd` | session ended (`reason`) | `sessionEnded` |

Explicit `mactamagotchi-hook report …` calls arrive as `report` events (build/test/milestone/commit).

### Installed configuration

One group per event, without a matcher (matches everything), added after any existing groups:

```json
"PreToolUse": [
  { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/bin/your-own-hook.sh" }] },
  { "hooks": [{ "type": "command",
                "command": "'/Users/you/Library/Application Support/MacTamagotchi/bin/mactamagotchi-hook' claude-hook PreToolUse 2>/dev/null || true",
                "timeout": 5 }] }
]
```

- Hooks are **synchronous but tiny** (median 4.4 ms, p95 ≈ 10 ms measured; 36 ms for a 5 MB payload). Synchronous
  keeps delivery reliable in `claude -p`, where async hooks are cancelled at teardown. The helper has a
  hard 3-second internal deadline, and `timeout: 5` bounds it from Claude Code's side.
- `SessionEnd` gets no `timeout`, so Claude Code's short default shutdown budget is not raised.
- The helper prints nothing (stdout of `SessionStart` / `UserPromptSubmit` hooks would otherwise be added
  to Claude's context) and always exits 0, so it can never block or alter Claude's behaviour.
- Entries are recognized as ours by `mactamagotchi-hook` + ` claude-hook` in the command; removal touches nothing else.

## The helper: sanitizing in the hook process

`mactamagotchi-hook claude-hook <Event>` reads the hook's stdin and keeps an **allow-list**:

`hook_event_name`, `session_id`, project name (from `CLAUDE_PROJECT_DIR` or `cwd`) plus a one-way hash and
the path (memory-only in the app), `tool_name`, `tool_use_id`, a tool category, an exit code number,
`is_interrupt`, `duration_ms`, `notification_type` and Claude Code's short `message` (≤ 160 chars),
`agent_type`/`agent_id`, `source`, `reason`/error type, `model`, `permission_mode`, batch size/tool names,
and for Bash commands only a **kind** (`test`/`build`) plus whether its exit status is trustworthy.

Dropped inside the hook process: `prompt`, `tool_input` (after classification), `tool_response`, `error` text,
`transcript_path`, `custom_instructions`, `error_details`, everything else. `last_assistant_message` (on Stop)
and the name of a changed file (on PostToolUse of an editing tool) are kept only while the user shares
summaries with their iPhone, which the helper learns from a `share-summaries` file in the app's private
folder. The app summarizes them in memory and strips them before the world sees the event; the helper strips
them before spooling.

Each event's id is a digest of the raw payload, so a duplicated delivery is recognized and ignored.
Payloads over 8 MB are not parsed; a bounded scan of the first 64 KB still reports the event.

## The bridge

- Unix domain socket `run/bridge.sock` inside a 0700 directory, mode 0600; **no TCP port**.
- Every connection's peer is checked with `getpeereid`; other users are refused.
- One newline-terminated JSON line per connection (max 32 KB), 2 s read deadline, 16 concurrent connections.
- Each line is schema-validated (version, field types and lengths, identifier character sets,
  timestamp window, report shape) before anything else sees it; the client gets `ok` or `rejected <code>`.
- Runs on its own queue and acknowledges before UI work, so animations can never slow Claude Code down.
- Self-healing: a stale socket file is replaced; a deleted socket is recreated within seconds; a second
  instance never steals a live socket.
- When nothing is listening the helper appends to a bounded spool (512 KB, oldest half dropped and counted).
  The app drains it at launch and every 30 s, delivers those events as **late** (history only, no reactions),
  and tells you how many arrived and how many were dropped.

## From events to state

Each session is tracked separately (`SessionRegistry`):

`idle` → `promptSubmitted` → `runningTool` ⇄ `thinking` → `turnCompleted` · `waitingForUser` · `turnFailed` · `ended`

- Parallel tools are tracked by `tool_use_id`; a success returns to `thinking` unless others are running.
- A successful tool call **never** completes a turn; only `Stop` does. `StopFailure` is an API error, not a completion.
- Waiting clears when the tool proceeds, the batch resolves, a new prompt arrives or the turn ends.
- Three consecutive tool errors start detective mode; a success resets the streak.
- Interrupts are not counted as failures.
- Late events update history but never move a session backwards in time.
- Sessions with no events for 20 minutes while “working” are shown as possibly closed.

**Primary session rule** (what the menu bar shows): a pinned session while alive; otherwise
waiting-for-you › API error or tool error in the last minute › working › turn completed in the last 5 minutes
› open › recently ended; ties go to the most recent event. Other sessions' completions are acknowledged
with a project-labelled caption without taking over the scene.

## From state to animation

| Observed | Pet | Patch |
|---|---|---|
| Session starts | curious greeting | arrives, opens the laptop (welcome) |
| Prompt submitted | leans forward | reads a task card, then thinks |
| `Read` | watches | reading a page |
| `Grep` / `Glob` | watches | magnifying glass |
| `Edit` / `Write` | watches | typing, code on the holo-screen |
| `Bash` | watches | watching a terminal |
| `WebFetch` / `WebSearch` | watches | browsing |
| `Agent` / subagents | looks around | delegating to tiny helper bots |
| any other tool (MCP, skills…) | watches | **generic** typing — no claim about what it does |
| Tool succeeded | small nod | continues the current loop |
| Recognized test/build exited 0 (trustworthy) | happy bounce | nod; trophy when the turn ends |
| Tool failed | concerned | examines a tiny error board (“Claude may still be working on it”) |
| 3 failures in a row | confused tilt | puts on the detective hat |
| Waiting for you | gentle wave | hand raised, lock/… speech bubble, amber antenna |
| Turn complete | victory | high five · victory dance (long, live-observed turn) · trophy (real result) · case closed |
| API error | concerned | concerned, alert antenna |
| Session ends | wave | packs up, rests with coffee, departs after the linger time |
| Bridge unavailable | neutral | offline visor, “no signal” bubble |

These are visual mappings, not claims about Claude's reasoning.

## Compatibility

`HookCompatibility` searches the installed CLI (native binary or `cli.js`) for each event name as a string
literal. A real build must contain all core events or the scan is ignored. If detection isn't possible,
only `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`,
`SubagentStop` and `SessionEnd` are installed. Unknown events that still arrive are recorded as
“unrecognized” in diagnostics and never animate. Newer wire schema versions are rejected with a clear
diagnostic rather than misread.

## Ask Mochi's helper session

Ask Mochi doesn't change your Claude Code settings. When a request needs Claude, the app starts its own
`claude -p` session named `mochi`, using your login, with no settings, hooks or MCP servers of yours (see
ARCHITECTURE.md › Ask Mochi for the exact flags). It reaches your other sessions only through Claude Code's
documented cross-session messaging (Claude Code 2.1.224 or later):
- **Discovery:** it finds them with `ListAgents`.
- **Sending:** it sends with `SendMessage`, which is always an *ask* rule answered by Mochi's approval card.
- **What the session sees:** the message as "Message from @mochi". It can't approve anything there, and
  that session's own permission prompts still apply.
- **Delivery timing:** a session that is idle starts a new turn with the message; a busy one reads it
  between tool calls.
- **Bypass-permissions sessions:** a session running in *bypass permissions* holds messages from other
  sessions for approval, and the VS Code extension can't show that approval, so such sessions don't receive
  Mochi's prompts.

The hook helper also gained a `paws` subcommand. The helper session uses it to reach Mochi's tools: MCP over
a private socket, with a one-time token.

