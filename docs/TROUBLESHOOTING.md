# Troubleshooting

Start with **Settings › Claude Code**: it shows the detected CLI, supported events, connection and bridge
state, bridge statistics, and has **Test Connection**, **Reveal Settings File**, **Show Backups** and
**Copy Diagnostics** (no sensitive data). **Activity** shows every event per session.

| Symptom | What to check |
|---|---|
| “Claude Code not found” | MacTamagotchi looks in `~/.local/bin`, `~/.claude/local`, Homebrew, `/usr/local/bin`, npm/bun/volta/pnpm global bins and `PATH`. The pet works without it. |
| “Connected — waiting for a Claude Code session” | Hooks are installed but no event arrived yet. Start a **new** session (open sessions read hooks at startup). Inside Claude Code, `/hooks` should list `mactamagotchi-hook` entries. |
| “Connection needs an update” | The helper path changed or an event became available. Press **Update Connection…**. |
| “Hooks are disabled …” | Your settings contain `"disableAllHooks": true`. Claude Code runs no hooks until you change it. |
| “Your organization only allows managed hooks” | Managed settings set `allowManagedHooksOnly`; ask your administrator. |
| “settings are not valid JSON” | MacTamagotchi refuses to edit a file it can't parse (comments, trailing commas). Nothing was changed. Fix the file, then connect. |
| “Event bridge unavailable — Another MacTamagotchi instance is already listening” | Quit the other copy (only one instance runs per data directory). |
| Events arrive “late” | They were spooled while the app wasn't running (or the bridge restarted). They're shown in history without reactions. |
| “events were dropped” | The spool keeps 512 KB; the oldest half is dropped when full, and events older than a day are discarded. |
| No sounds | Sound is off by default (Settings › Notifications). Quiet hours/mode silence sounds; so does macOS “Play user interface sound effects” being off. |
| No banners | Banners are off per category by default; enable them and allow notifications. They need the app bundle (not `swift run`), and are never sent for simulated or late events, during quiet hours, or while the popover is open. |
| The desktop pet doesn't respond to clicks | “Let clicks pass through” is on. Hide/show with ⌃⌥⌘P or the menu bar. |
| The desktop pet vanished | Check the popover's **Desktop** chip; positions are kept on a visible display when screens change; Settings › Desktop Pet › **Reset Position**. |
| Menu bar icon missing | On notched MacBooks, too many menu bar items can hide some. Remove others or use a menu bar manager. |
| The characters stopped reacting | **Pause** is on (popover chip or right-click menu). Sessions still update while paused. |

## Verifying the pipeline by hand

```bash
HOOK="$HOME/Library/Application Support/MacTamagotchi/bin/mactamagotchi-hook"
"$HOOK" ping                                        # is the app listening?
echo '{"session_id":"manual-1","hook_event_name":"SessionStart","source":"startup","cwd":"'"$PWD"'"}' \
  | "$HOOK" claude-hook SessionStart                 # exactly what Claude Code does
```

The helper always exits 0 and prints nothing in `claude-hook` mode; use `ping` for a readable answer.

## Restoring Claude Code settings

Every change wrote a copy to `~/Library/Application Support/MacTamagotchi/Backups/claude-settings-<timestamp>.json`.
Copy one back to `~/.claude/settings.json` to restore that exact state.
