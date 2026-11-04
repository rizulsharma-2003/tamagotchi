#!/bin/bash
# End-to-end checks against an isolated app instance. Never touches your real
# MacTamagotchi data or ~/.claude: everything lives in a temporary directory.
#
#   scripts/e2e.sh                 # helper → bridge → app, privacy, spool/late delivery, installer on a settings copy
#   scripts/e2e.sh --with-claude   # also runs a short real `claude -p` session through the hooks (uses a little API usage)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MacTamagotchi.app"
BIN="$APP/Contents/MacOS/MacTamagotchi"
WITH_CLAUDE=0
[[ "${1:-}" == "--with-claude" ]] && WITH_CLAUDE=1

[[ -x "$BIN" ]] || "$ROOT/scripts/build-app.sh"

WORK="$(mktemp -d /tmp/mtg-e2e.XXXXXX)"
export MACTAMAGOTCHI_HOME="$WORK/home"
export MACTAMAGOTCHI_CLAUDE_SETTINGS="$WORK/claude-settings.json"
export MACTAMAGOTCHI_DEBUG_STATE=1
HOOK="$MACTAMAGOTCHI_HOME/bin/mactamagotchi-hook"
APP_PID=""
FAILURES=0

cleanup() {
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
state() { python3 -c "import json,sys; d=json.load(open('$MACTAMAGOTCHI_HOME/debug-state.json')); print($1)"; }

start_app() {
    "$BIN" >"$WORK/app.log" 2>&1 &
    APP_PID=$!
    for _ in $(seq 1 50); do
        "$HOOK" ping >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    return 1
}

stop_app() {
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
}

hook() { # hook <EventName> <json>
    echo "$2" | "$HOOK" claude-hook "$1"
}

echo "== Installer (on a copy of a settings file with your own hooks)"
cat >"$MACTAMAGOTCHI_CLAUDE_SETTINGS" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "echo user-hook" }] }]
  },
  "permissions": { "allow": ["Bash(git status)"] }
}
JSON
cp "$MACTAMAGOTCHI_CLAUDE_SETTINGS" "$WORK/original.json"
"$BIN" --integration connect >"$WORK/connect.log"
check "connect installs every supported event" "grep -q 'Status: installed' '$WORK/connect.log'"
check "a backup of the original file is written" "ls '$MACTAMAGOTCHI_HOME/Backups/' | grep -q claude-settings-"
check "existing user hook and settings are preserved" "python3 - <<PY
import json
a=json.load(open('$MACTAMAGOTCHI_CLAUDE_SETTINGS')); b=json.load(open('$WORK/original.json'))
assert a['model']==b['model'] and a['permissions']==b['permissions']
assert a['hooks']['Stop'][0]==b['hooks']['Stop'][0]
PY"
check "the helper was installed" "[[ -x '$HOOK' ]]"

echo "== Live delivery"
check "app starts and the bridge answers" "start_app"
SECRET="sk-test-SECRET-$(date +%s)"
CWD="$WORK/proj/InsideEdge"; mkdir -p "$CWD"
hook SessionStart "{\"session_id\":\"e2e-1\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$CWD\",\"transcript_path\":\"/tmp/$SECRET.jsonl\"}"
hook UserPromptSubmit "{\"session_id\":\"e2e-1\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"my key is $SECRET\",\"cwd\":\"$CWD\"}"
hook PreToolUse "{\"session_id\":\"e2e-1\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"echo $SECRET\"},\"cwd\":\"$CWD\"}"
hook PostToolUseFailure "{\"session_id\":\"e2e-1\",\"hook_event_name\":\"PostToolUseFailure\",\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"error\":\"Exit code 2\\n$SECRET\",\"cwd\":\"$CWD\"}"
hook PreToolUse "{\"session_id\":\"e2e-1\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_use_id\":\"t2\",\"tool_input\":{\"command\":\"swift test\"},\"cwd\":\"$CWD\"}"
hook PostToolUse "{\"session_id\":\"e2e-1\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_use_id\":\"t2\",\"tool_input\":{\"command\":\"swift test\"},\"tool_response\":{\"stdout\":\"$SECRET\"},\"cwd\":\"$CWD\"}"
sleep 1.5
check "a tool success does not complete the turn" "[[ \$(state \"d['sessions'][0]['phase']\") == thinking ]]"
hook Notification "{\"session_id\":\"e2e-1\",\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to use Bash\",\"cwd\":\"$CWD\"}"
sleep 1.5
check "a permission prompt puts the session in waitingForUser" "[[ \$(state \"d['sessions'][0]['phase']\") == waitingForUser ]]"
check "the menu bar shows the attention badge" "[[ \$(state \"d['menuBar']['badge']\") == attention ]]"
hook Stop "{\"session_id\":\"e2e-1\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"last_assistant_message\":\"$SECRET\",\"cwd\":\"$CWD\"}"
sleep 1.5
check "Stop completes the turn" "[[ \$(state \"d['sessions'][0]['phase']\") == turnCompleted ]]"
check "the reliable test command is reported as a real result" "state \"d['sessions'][0]['buildTest']\" | grep -q 'test command'"
check "no event was rejected" "[[ \$(state \"d['connection']['rejected']\") == 0 ]]"
check "nothing sensitive reached history" "! grep -q '$SECRET' '$MACTAMAGOTCHI_HOME/history.jsonl'"
check "full project paths are not stored" "! grep -q '$CWD' '$MACTAMAGOTCHI_HOME/history.jsonl'"
REPLY=$(python3 - <<'PY'
import os, socket
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(os.environ["MACTAMAGOTCHI_HOME"] + "/run/bridge.sock")
sock.sendall(b'{"not": "an event"}\n')
print(sock.recv(64).decode().strip())
PY
)
check "malformed input is rejected by the bridge ($REPLY)" "[[ '$REPLY' == rejected* ]]"

echo "== Missed events while the app is not running"
stop_app
hook SessionStart "{\"session_id\":\"e2e-2\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$CWD\"}"
hook Stop "{\"session_id\":\"e2e-2\",\"hook_event_name\":\"Stop\",\"cwd\":\"$CWD\"}"
check "events are spooled while the app is down" "[[ -s '$MACTAMAGOTCHI_HOME/spool/pending.jsonl' ]]"
start_app >/dev/null
sleep 2
check "spooled events arrive as late history" "[[ \$(state \"(d['missed'] or {}).get('delivered')\") == 2 ]]"
check "late events do not replay celebrations" "[[ \$(state \"d['interaction']\") != highFive ]]"

if [[ "$WITH_CLAUDE" == "1" ]]; then
    echo "== Real Claude Code session"
    BEFORE=$(state "d['connection']['accepted']")
    (cd "$CWD" && env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" LANG=en_US.UTF-8 \
        claude -p "Run 'echo mactamagotchi-e2e' with the Bash tool, then reply with one word." \
        --settings "$MACTAMAGOTCHI_CLAUDE_SETTINGS" --setting-sources user --model sonnet \
        --allowedTools "Bash(echo:*)" --max-turns 3 </dev/null >"$WORK/claude.log" 2>&1) || true
    sleep 2
    AFTER=$(state "d['connection']['accepted']")
    check "a real session delivered hook events ($BEFORE → $AFTER)" "(( AFTER > BEFORE + 4 ))"
fi

echo "== Disconnect"
stop_app
"$BIN" --integration disconnect >"$WORK/disconnect.log"
check "disconnect restores the settings exactly" "python3 -c \"import json; assert json.load(open('$MACTAMAGOTCHI_CLAUDE_SETTINGS'))==json.load(open('$WORK/original.json'))\""

if (( FAILURES > 0 )); then
    echo "$FAILURES check(s) failed. App log:"; tail -20 "$WORK/app.log"
    exit 1
fi
echo "All end-to-end checks passed."
