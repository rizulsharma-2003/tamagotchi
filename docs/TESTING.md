# Testing

## Automated

```bash
swift test                       # 328 tests in 38 suites (Swift Testing), ~6 s
scripts/e2e.sh                   # 18 end-to-end checks against an isolated app instance
scripts/e2e.sh --with-claude     # + a short real `claude -p` session through the hooks
```

Results on macOS 27.0, Xcode 27.0, Swift 6.4, Claude Code 2.1.309: **all 130 tests pass, all end-to-end
checks pass (including `--with-claude`)**. After the animation and menu-bar work: 197 tests (adds PetAnimationTests and RoamingTests).
After the pixel mascot and the twelve playful features: **288 tests in 32 suites pass**; the release build has no warnings.
With Ask Mochi: **307 tests in 36 suites pass**. Ask Mochi was also run live against an isolated instance and a
throwaway `claude -p` target session:
- a quick command;
- the full path of helper session → approval card → Send → delivery → the target's turn → Mochi's
  "Claude finished" bubble (about 13 s end to end);
- the decline and cancel paths;
- a tool call through the relay;
- an ambiguous session name, where the helper asked which one;
- off-screen captures of the real panel;
- on-device transcription of a synthesized spoken command (0.3 s).

The iPhone companion was checked too:
- built for the iOS 27 simulator and then the real iPhone 14 Pro, team-signed and installed with `devicectl`;
- the iPhone's push addresses reached the Mac through iCloud key-value storage within 2 seconds.
- commands from the phone round-tripped through iCloud on the real devices: a quick command answered in
  about 14 seconds; an approval mirrored to the phone was approved there and the test session replied "pong";
  hold-to-talk was tried by the user (YouTube opened on the Mac);
- the font animation advances once a second, checked with simulator screenshots a second apart.

With the iPhone tests: **314 tests in 37 suites pass**. With the phone room, summaries and the listening pose:
**326 tests in 38 suites pass**. With Mochi keeping the Mac's rhythm: **328 tests in 38 suites pass**; the three readings (input idle time, screen-on assertions, processor load) were checked on this Mac. The hook helper was also run against a stand-in app socket: Claude's
message and file names went through only with `share-summaries` present, and never into the spool. The
summarizer's exact command line was run once: about 3.6 seconds, $0.0005, and a valid note.

| Suite | Covers |
|---|---|
| Hook payload sanitizer | prompts / tool input / output / error text / transcript paths are dropped; exit codes; notification text bounds; StopFailure; malformed and oversized payloads; duplicate-delivery ids; subagent context |
| Claude's summaries for the iPhone | the message and file names only with the opt-in; names never paths; never journaled; line-break cleaning; a turn's files per session; the summarizer's JSON and fallback; markdown to plain text; session list and alert payload; replies keep the user's words |
| Command classifier | 12 build/test command forms incl. pipelines, `|| true`, `;`, background runs; non-matches |
| Event schema validation | well-formed, oversized, malformed, newer schema versions, injected identifiers, implausible timestamps, missing optional fields, unknown event names, report shape |
| Normalizer semantics | distinct kinds per state; notification mapping; tool success ≠ completion; completion ≠ build claims; only trustworthy commands produce outcomes |
| Session state machine | full turn, parallel tools, detective mode, interrupts, permission waits, no session mixing, primary-session rule incl. pinning, stale sessions, late out-of-order events, joining mid-session, report attachment |
| Event → animation mapping | small tool reactions, celebrations, trophy, concern, detective → case closed, permission pair reacts once, non-primary sessions, specific vs generic work loops, unknown events, long-turn trust |
| Character animator | priority interrupts, fall back to current base, cooldowns, obsolete tokens, every pose finite in every animation (and no translation/rotation with reduced motion), every interaction script returns home |
| Interaction scheduler | deterministic per seed, gaps/cooldowns/no repeats/rare caps, nothing while waiting or paused, working-context rules, postponement after events |
| Ordered JSON | order/number preservation, unicode, invalid JSON, agreement with Foundation |
| Hook installer | missing file, preservation of existing hooks/settings/order/trailing newline, idempotence, outdated path update, uninstall removes only ours, hooks key removal, malformed and unexpected shapes refused untouched, symlinked settings, tamper detection, quoting and fail-safe commands, SessionEnd budget, disableAllHooks/managed-hooks detection, backup pruning, compatibility detection and fallback |
| Event journal | refuses simulated events, duplicates, persistence, path stripping, retention by age and count, zero retention, corrupt lines |
| Settings | persistence, tolerant decoding, garbage → defaults |
| Quiet hours and notification policy | overnight windows, quiet silences sound/banners but keeps animation/badge, master sound switch, pause, simulated/late events, tool activity never banners, banner coalescing |
| Achievements and friendship | real/live events only, green build needs a real outcome, distinct projects, daily caps, no decay, seven distinct days, accessory unlocks/seasons |
| Local event bridge | delivery + 0600 socket, malformed/oversized rejection, unavailable when not running, stale socket replaced, no stealing a live socket, recovery after the socket file is deleted, slow clients don't block |
| Spool | append/drain, bounded with drop counting, provider delivers spooled events as late |
| World scenarios | the end-to-end pipeline with a controllable clock (see the scenario table) |
| Speech lines and pacing | every occasion has short lines, real events map to occasions, no repeats, chattiness pacing, generated lines cleaned or rejected, the switch and expiry, reactions reach the speech hook |
| Life stages | growth needs friendship *and* time together, never goes backwards, explains the next step |
| Desktop adventures | seeded routes, continuity, stays on screen, ends in the bar, Dock sit, climbing the edge nearest home, no windows, re-planning when windows change, hurry home, terrain filtering, spontaneous scheduling |
| Notch den | only with a notch and the setting on, clipping on both sides and right-to-left, peek when Claude waits, burst on celebrations, away and return |
| Catch the Treats · Rock, paper, scissors | scoring, combos, misses and game over, speed-up, determinism; three-way outcomes, tallies, streaks |
| Focus buddy · Daily recap | phase machine, skips, long breaks, sleep through a block; recap numbers from real events only, quiet days, honest streaks |
| Ask Mochi: quick commands | music, volume, focus, Mochi's tricks, apps and sites; wake words and politeness stripped; anything unsure goes to Claude |
| Ask Mochi: tool server protocol | MCP handshake and version negotiation, tool list and calls, unknown tools and methods, notifications, parse errors |
| Ask Mochi: helper Claude session | locked-down launch flags, MCP relay config, stream-json input, context line (names only), event-stream parsing, step text, session names ↔ projects |
| iPhone Live Activity | the most urgent live session wins, project names private by default, ends after done/idle, simulated sessions ignored, urgent vs quiet updates, payloads match the iPhone app's model, ES256 token verifies, tolerant settings |
| Ask Mochi: settings and wire | tolerant decoding of old/partial settings, host app identifier carried and validated, separate paws socket path |
| Season calendar · Room makeover | event windows and priorities (Diwali by year, birthdays), greetings once per occasion; furniture unlocks, snapping to wall/floor bands, limits, sanitizing |

## Scenarios from the brief

“Live” means the built app ran as an isolated instance (`MACTAMAGOTCHI_HOME` in a temp dir, a copy of the
settings file) and its state was read back through `MACTAMAGOTCHI_DEBUG_STATE`; “real Claude” means events came
from actual `claude -p` sessions (2.1.309) using the installed hooks.

| # | Scenario | Verified by | Result |
|---|---|---|---|
| 1 | Launch without Claude Code | live (`MACTAMAGOTCHI_CLAUDE_BIN=/nonexistent`), `worksWithoutClaudeCode` | “Claude Code not found”, bridge listening, pet fully usable |
| 2 | Installed but disconnected | live, headless `--integration status` | “Claude Code not connected” + Set Up…; status `notInstalled` |
| 3 | A session starts | real Claude, `sessionStartBringsTheCompanion` | companion arrives (welcome interaction) |
| 4 | A prompt is submitted | real Claude | `promptSubmitted`; prompt text absent from history (grep) |
| 5 | Several tool calls | real Claude (4 tools; two concurrent sessions) | tracked per `tool_use_id`, per session |
| 6 | Tool succeeds, turn continues | real Claude, e2e, `toolSuccessDoesNotCompleteTheTurn` | phase `thinking`, no celebration, no result card |
| 7 | A tool fails | real Claude (`cat missing-file.txt`) | “Bash reported an error (exit code 1)”, concern, info badge, caption with project |
| 8 | Claude needs user input | real Claude (`PermissionRequest`), e2e (`Notification permission_prompt`) | `waitingForUser`, NEEDS YOU, orange badge, lock bubble |
| 9 | A turn finishes | real Claude | `turnCompleted`, result card, trophy because `make test` exited 0 reliably |
| 10 | A session ends | real Claude, `companionLeavesAfterTheLastSessionEnds` | packs up, rests, departs after the linger time |
| 11 | Two sessions active | real Claude (two parallel sessions in two projects) | separate phases/failure counts; menu bar follows the documented rule; captions labelled |
| 12 | App restarts during a session | real Claude (app killed mid-session, restarted) | 14 spooled events delivered as LATE, no reactions replayed, “events arrived while not listening” notice |
| 13 | Event bridge unavailable | live (app killed), `recoversWhenTheSocketFileIsDeleted`, `connectionLossShowsOfflineAndRecovers` | hooks spool in ~4 ms and exit 0; deleted socket recreated; offline state |
| 14 | Hook installation fails | live (settings with a comment), installer tests | refused with a clear message, file byte-identical |
| 15 | Existing hooks present | real Claude with merged settings | user's Stop and PreToolUse hooks ran **and** the app received events; Disconnect restored the file exactly |
| 16 | Quiet hours active | live (quiet mode, full simulated turn), policy tests | 0 sounds requested, animations still shown |
| 17 | Reduced Motion | live (`reducedMotion: always`), pose tests | reduced mode active; no translation, rotation or squash |
| 18 | Desktop pet hidden and restored | live (window list + captures) | hidden/shown at the same position; saved position restored on the right display after restart |

## Performance (release build, measured with `top`)

| State | CPU |
|---|---|
| Menu bar only, idle | ≈ 0.2 % |
| Claude working (antenna pulse) | ≈ 2 % |
| Popover open | ≈ 1.6 % |
| Desktop pet visible | ≈ 5 % of one core |
| Hook helper per event | median 4.4 ms, p95 ≈ 10 ms; 36 ms for a 5 MB payload |

Two issues found and fixed during this measurement: scenes in closed windows kept animating (now paused by
`WindowVisibilityReader`), and the audio engine kept running after a sound (now stopped after playback).

## Visual checks

`MacTamagotchi --render-snapshots <dir>` renders every pet and companion state, all themes in light and dark,
interactions, accessories, menu-bar glyphs. With `MACTAMAGOTCHI_DEBUG_STATE=1`, writing `popover`,
`settings:<tab>`, `activity`, `welcome`, `desktop`, `simulate:<scenario>` or `interaction:<id>` to
`<home>/debug-request` opens that UI and saves a snapshot.

## Known limitations and manual verification

- **Not produced by a live session during development** (verified with exact documented payloads and the
  simulator instead): `Notification` `idle_prompt` / interactive `permission_prompt` / elicitation types,
  `SubagentStart` / `SubagentStop`, `StopFailure` (needs a real API error), `PostToolBatch` with several calls.
- **Escape during a permission prompt**: Claude Code sends no `Stop` for user interrupts, so the session can show
  “waiting” until the next event; Claude Code's `idle_prompt` notification (after ~60 s) corrects it to
  “waiting for your input”.
- **Click-through on transparent parts of the desktop pet** relies on macOS hit-testing of non-opaque windows;
  dragging and clicking were not automated (that needs Accessibility permission). Please try them by hand.
- **Sounds** were exercised at volume 0; listen with Settings › Notifications › Test. **Banners** need the app
  bundle and your permission and are off by default. **Open at login** needs the app in an Applications folder.
  **⌃⌥⌘P** is registered but wasn't pressed in automated runs.
- **Distribution**: builds are ad-hoc signed; notarization needs your Developer ID (`SIGN_IDENTITY`).
- Only run on macOS 27; the deployment target is macOS 14.
- Hook changes apply to **new** Claude Code sessions; restart open ones.
