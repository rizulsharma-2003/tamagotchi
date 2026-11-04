# Setup

## 1. Build and install

```bash
scripts/build-app.sh --install
open ~/Applications/MacTamagotchi.app
```

`build-app.sh` runs `swift build -c release`, assembles `build/MacTamagotchi.app` (app binary in
`Contents/MacOS`, hook helper in `Contents/Helpers`, generated icon, `LSUIElement` Info.plist) and
signs it ad hoc. Options:

| Variable / flag | Effect |
|---|---|
| `--install` | Copy the app to `~/Applications` |
| `UNIVERSAL=1` | Build arm64 + x86_64 |
| `SIGN_IDENTITY="Developer ID Application: …"` | Sign with your identity (needed for notarization/distribution) |
| `VERSION`, `BUILD_NUMBER`, `BUNDLE_ID` | Bundle metadata |

MacTamagotchi is not sandboxed: it needs to edit `~/.claude/settings.json` (only when you press
Connect/Disconnect) and to listen on a socket in its own Application Support folder.

On first launch a welcome window introduces the characters. The pet works right away; Claude Code is optional.

## 2. Connect Claude Code

Menu bar pet › **Set Up…**, or **Settings › Claude Code**:

1. **Status** shows where `claude` was found, its version, and the bridge state.
2. **Events** lists the hook events the installed version supports. They are detected by inspecting the
   installed CLI; if that is impossible only long-established events are used, so an unknown event
   name is never written into your settings.
3. **Preview Changes** shows the exact JSON that will be written.
4. **Connect Claude Code…** asks for confirmation, then:
   - copies the helper to `~/Library/Application Support/MacTamagotchi/bin/mactamagotchi-hook`
     (a stable path, so hooks keep working if the app moves),
   - writes a timestamped backup to `~/Library/Application Support/MacTamagotchi/Backups/`,
   - merges one hook group per event, keeping every existing setting and hook in place and in order,
   - verifies the result by re-parsing it and checking nothing else changed, then writes atomically
     (following a symlinked settings file to its target),
   - pings the bridge through the installed helper.
5. Start a **new** Claude Code session. Sessions that were already open read hooks at startup; restart
   them, or check `/hooks` inside Claude Code to see the entries.

Each installed command looks like:

```
'/Users/you/Library/Application Support/MacTamagotchi/bin/mactamagotchi-hook' claude-hook PreToolUse 2>/dev/null || true
```

It always exits 0 and prints nothing, even if MacTamagotchi was deleted.

### Headless setup

The same installer is available without UI:

```bash
MacTamagotchi.app/Contents/MacOS/MacTamagotchi --integration status     # what's detected and installed
MacTamagotchi.app/Contents/MacOS/MacTamagotchi --integration preview    # the JSON that would be written
MacTamagotchi.app/Contents/MacOS/MacTamagotchi --integration connect
MacTamagotchi.app/Contents/MacOS/MacTamagotchi --integration disconnect
```

`MACTAMAGOTCHI_CLAUDE_SETTINGS=/path/to/settings.json` points it at another file (e.g. a copy, or a
project's `.claude/settings.json`).

## 3. Report real build and test results (optional)

A finished turn says nothing about whether code builds. To celebrate real results, report them:

```bash
HOOK="$HOME/Library/Application Support/MacTamagotchi/bin/mactamagotchi-hook"
swift test && "$HOOK" report test passed || "$HOOK" report test failed
xcodebuild -scheme App build && "$HOOK" report build passed --label "Xcode"
flutter test && "$HOOK" report test passed --label "Flutter"
"$HOOK" report milestone reached --label "Shipped v1"
"$HOOK" report commit reached          # e.g. from a git post-commit hook
```

`report` never changes your script's exit status. If the app isn't running the report is kept and shown as late.

MacTamagotchi also recognizes build/test **commands Claude runs** (`swift test`, `npm test`, `pytest`,
`xcodebuild test`, `cargo build`, `make`, …) but only treats them as a result when the exit status is
trustworthy: pipelines, `|| true`, trailing `;` commands and background runs are never treated as
passing. Turn this off in Settings › Claude Code.

## 4. Desktop pet (optional)

Settings › Desktop Pet, the popover's **Desktop** chip, or **⌃⌥⌘P**. Drag to move, click to pet,
right-click for options (Hide, Always on Top, Settings). Positions are remembered per display and
kept on screen when displays change. “Let clicks pass through” makes the pet ignore the mouse
entirely; hide it with ⌃⌥⌘P or the menu bar.

## 5. Isolated / development runs

```bash
MACTAMAGOTCHI_HOME=/tmp/mtg-dev MacTamagotchi.app/Contents/MacOS/MacTamagotchi
```

`MACTAMAGOTCHI_HOME` gives the app (and its hooks, which carry the variable) a separate data
directory, socket, history and helper. `MACTAMAGOTCHI_CLAUDE_BIN=/nonexistent` simulates “Claude Code
not installed”. `MACTAMAGOTCHI_DEBUG_STATE=1` writes `debug-state.json` and enables window snapshots
(see [TESTING.md](TESTING.md)).

## Data locations

All under `~/Library/Application Support/MacTamagotchi/` (directory mode 0700):

| Path | Contents |
|---|---|
| `settings.json` | App settings |
| `history.jsonl` | Sanitized event history (retention configurable, max 2,000 events) |
| `progress.json` | Friendship points and achievements |
| `run/bridge.sock` | The local event socket (0600). Falls back to `/tmp/mactamagotchi-<uid>/` if the path is too long |
| `spool/pending.jsonl` | Events received while the app wasn't running (bounded to 512 KB) |
| `bin/mactamagotchi-hook` | The installed hook helper |
| `Backups/` | Copies of `~/.claude/settings.json` taken before every change (last 20 kept) |

## Uninstall

1. Settings › Claude Code › **Disconnect** (or `--integration disconnect`). Only MacTamagotchi's hook
   entries are removed, after a backup.
2. Settings › General: turn off “Open at login” if you enabled it.
3. Quit MacTamagotchi and move it to the Trash.
4. Optionally delete `~/Library/Application Support/MacTamagotchi/`.

If you delete the app without disconnecting, the hooks stay harmless (`|| true`), but you can remove
any entry whose command contains `mactamagotchi-hook claude-hook` from `~/.claude/settings.json`.
