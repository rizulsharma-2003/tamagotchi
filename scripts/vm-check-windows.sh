#!/bin/bash
# One routine check of Mochi for Windows (this checkout's HEAD) on the UTM Windows VM, the same way every time, and
# leaves the VM as it found it. Made for cheap, scripted verification between builder agents (docs/SPRINT_2.md).
#
#   scripts/vm-check-windows.sh [--no-tests] [--no-build] [--perf SECONDS] [--screen-off] [--click]
#                               [--env KEY=VALUE]... [--out DIR]
#
#   1. Sends `git archive HEAD flutter link-spec` (no ._ files) to C:\src\mochi-check on the VM, keeping the previous
#      build folders there so builds are incremental.
#   2. `flutter test` in mochi_desktop (unless --no-tests): the summary and the failing tests' names.
#   3. `flutter build windows --release` (unless --no-build).
#   4. Runs that build on the signed-in desktop instead of the VM's own Mochi, with its outbound network blocked (it
#      never reaches the relay), the perf meter on and the display kept awake. --env sets variables for it (e.g. a
#      demo switch a builder added). Screenshots: "start" (15 s in), "popover" (with --click: hovers and clicks
#      Mochi), "end" (after --perf seconds, default 120). With --screen-off it then lets the display sleep and samples
#      again.
#   5. Always (even after a failure): stops the test build, restarts the VM's own Mochi (MochiLaunch) if it was
#      running, removes the firewall rule, the scheduled tasks and the perf switch, and restores the display timeout.
#
# Results go to build/vm-check/<time>/ (or --out): summary.txt, tests.log, perf.log, shots/*.png.
# Environment: MOCHI_VM [rizz@192.168.64.2], MOCHI_VM_KEY [~/.ssh/mochi_windows_vm].
set -euo pipefail

tests=1; build=1; perf=120; screen_off=0; click=0; envs=(); out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-tests) tests=0 ;;
    --no-build) build=0 ;;
    --perf) perf="$2"; shift ;;
    --screen-off) screen_off=1 ;;
    --click) click=1 ;;
    --env) envs+=("$2"); shift ;;
    --out) out="$2"; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "vm-check-windows: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

repo="$(cd "$(dirname "$0")/.." && pwd)"
vm="${MOCHI_VM:-rizz@192.168.64.2}"
vm_key="${MOCHI_VM_KEY:-$HOME/.ssh/mochi_windows_vm}"
dir='C:\src\mochi-check'
dir_fwd='C:/src/mochi-check'
rel="$dir\\flutter\\apps\\mochi_desktop\\build\\windows\\x64\\runner\\Release"
out="${out:-$repo/build/vm-check/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out/shots"
work="$(mktemp -d)"

say() { printf '\n== %s\n' "$*"; }
ssh_vm() { ssh -i "$vm_key" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 "$vm" "$@"; }
scp_to() { scp -i "$vm_key" -o BatchMode=yes -q "$1" "$vm:$2"; }
scp_from() { scp -i "$vm_key" -o BatchMode=yes -q "$vm:$1" "$2"; }
vm_ps() {
  local script="\$ProgressPreference = 'SilentlyContinue'
\$env:Path = 'C:\\src\\flutter\\bin;C:\\Program Files\\Git\\cmd;' + \$env:Path
$1"
  ssh_vm "powershell -NoProfile -NonInteractive -EncodedCommand $(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
}
# Runs a PowerShell file of ours on the signed-in desktop (an interactive scheduled task) and waits for it.
on_desktop() {
  local task="$1" args="$2" wait="${3:-15}"
  vm_ps "schtasks /Create /TN $task /TR 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass $args' /SC ONCE /ST 23:59 /IT /F | Out-Null
schtasks /Run /TN $task | Out-Null
for (\$i = 0; \$i -lt $((wait * 2)); \$i++) { Start-Sleep -Milliseconds 500; if ((schtasks /Query /TN $task /FO CSV /NH) -notmatch 'Running') { break } }" >/dev/null
}
shot() { on_desktop MochiCheckShot "-File $dir\\tools\\shot.ps1 -Folder $dir -Name $1"; scp_from "$dir_fwd/shots/$1.png" "$out/shots/$1.png" 2>/dev/null && echo "  shots/$1.png" || echo "  (no screenshot $1)"; }

ran_build=0
cleanup() {
  [ "$ran_build" = 1 ] || { rm -rf "$work"; return; }
  say "Putting the VM back"
  vm_ps "
Get-Process Mochi -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like '$dir*' } | Stop-Process -Force
Remove-NetFirewallRule -DisplayName 'mochi-check-no-network' -ErrorAction SilentlyContinue
foreach (\$t in 'MochiCheckRun','MochiCheckShot','MochiCheckWake','MochiCheckClick') { schtasks /Delete /TN \$t /F 2>\$null | Out-Null }
Remove-Item \"\$env:LOCALAPPDATA\\Mochi\\perf-debug\" -ErrorAction SilentlyContinue
\$saved = Get-Content '$dir\\display-timeout.txt' -ErrorAction SilentlyContinue
if (\$saved) { powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE ([Convert]::ToInt32(\$saved, 16)); powercfg /setactive SCHEME_CURRENT; Remove-Item '$dir\\display-timeout.txt' }
if ((Test-Path '$dir\\user-mochi-was-running.txt') -and -not (Get-Process Mochi -ErrorAction SilentlyContinue)) { schtasks /Run /TN MochiLaunch | Out-Null; Start-Sleep -Seconds 5 }
Remove-Item '$dir\\user-mochi-was-running.txt' -ErrorAction SilentlyContinue
'VM Mochi running: ' + [bool](Get-Process Mochi -ErrorAction SilentlyContinue)
'display timeout: ' + ((powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-String 'Current AC Power Setting Index').ToString().Trim())" | tee -a "$out/summary.txt" || true
  rm -rf "$work"
}
trap cleanup EXIT

say "Sending HEAD ($(git -C "$repo" rev-parse --short HEAD)) to $dir"
mkdir -p "$work/src/tools"
COPYFILE_DISABLE=1 git -C "$repo" archive --format=tar HEAD flutter link-spec | tar -xf - -C "$work/src"
cp "$repo"/scripts/vm/*.ps1 "$work/src/tools/"
find "$work/src" -name '._*' -delete
COPYFILE_DISABLE=1 tar -cf "$work/src.tar" -C "$work/src" flutter link-spec tools
scp_to "$work/src.tar" "C:/src/mochi-check-src.tar"
vm_ps "
New-Item -ItemType Directory -Force -Path '$dir' | Out-Null
# Fresh sources, kept build caches (build\\ and .dart_tool\\), so the build is incremental.
foreach (\$p in @('link-spec','tools','flutter\\packages')) { Remove-Item -Recurse -Force \"$dir\\\$p\" -ErrorAction SilentlyContinue }
Get-ChildItem '$dir\\flutter\\apps' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  Get-ChildItem \$_.FullName -Force | Where-Object { \$_.Name -notin @('build','.dart_tool') } | Remove-Item -Recurse -Force
}
tar.exe -xf C:\\src\\mochi-check-src.tar -C '$dir'
if (\$LASTEXITCODE -ne 0) { throw 'Unpacking failed.' }
Remove-Item C:\\src\\mochi-check-src.tar
Get-ChildItem -Path '$dir' -Recurse -Force -Filter '._*' -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item -Recurse -Force '$dir\\shots' -ErrorAction SilentlyContinue
'synced'"
echo "commit $(git -C "$repo" rev-parse --short HEAD)" > "$out/summary.txt"

if [ "$tests" = 1 ]; then
  say "Windows tests (mochi_desktop; about 6 minutes)"
  vm_ps "Set-Location '$dir\\flutter'; cmd /c 'flutter pub get 2>&1' | Out-Null
Set-Location '$dir\\flutter\\apps\\mochi_desktop'; cmd /c 'flutter test 2>&1' | Out-File -Encoding utf8 '$dir\\tests.log'" || true
  scp_from "$dir_fwd/tests.log" "$out/tests.log" || true
  LC_ALL=C sed 's/\x1b\[[0-9;]*m//g' "$out/tests.log" | tr '\r' '\n' | grep -aE '(All tests passed|Some tests failed)' | tail -1 | sed 's/^/tests: /' | tee -a "$out/summary.txt"
  LC_ALL=C sed 's/\x1b\[[0-9;]*m//g' "$out/tests.log" | tr '\r' '\n' | grep -aE '\[E\]$' | sed 's/^[0-9:]* [-+~0-9 ]*: /failed: /' | sort -u | head -20 | tee -a "$out/summary.txt" || true
fi

if [ "$build" = 1 ]; then
  say "Release build (about 7 minutes from clean, less when incremental)"
  vm_ps "Set-Location '$dir\\flutter\\apps\\mochi_desktop'; if (-not (Test-Path .dart_tool)) { cmd /c 'flutter pub get 2>&1' | Out-Null }
cmd /c 'flutter build windows --release 2>&1' | Select-Object -Last 3
if (\$LASTEXITCODE -ne 0) { throw 'build failed' }" | tee -a "$out/summary.txt"
fi

say "Running the build on the VM's desktop (network blocked, perf meter on)"
ran_build=1
env_lines="MOCHI_DESKTOP_INSTALL=never"
for kv in "${envs[@]+"${envs[@]}"}"; do env_lines+="\`r\`n$kv"; done
vm_ps "
if (Get-Process Mochi -ErrorAction SilentlyContinue | Where-Object { \$_.Path -notlike '$dir*' }) { Set-Content '$dir\\user-mochi-was-running.txt' yes }
Get-Process Mochi -ErrorAction SilentlyContinue | Stop-Process -Force
\$idx = (powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-String 'Current AC Power Setting Index').ToString().Split(':')[1].Trim()
if (-not (Test-Path '$dir\\display-timeout.txt')) { Set-Content '$dir\\display-timeout.txt' \$idx }
powercfg /change monitor-timeout-ac 0
New-NetFirewallRule -DisplayName 'mochi-check-no-network' -Direction Outbound -Action Block -Program '$rel\\Mochi.exe' | Out-Null
New-Item -ItemType File -Force -Path \"\$env:LOCALAPPDATA\\Mochi\\perf-debug\" | Out-Null
Remove-Item \"\$env:LOCALAPPDATA\\Mochi\\perf.log\" -ErrorAction SilentlyContinue
Set-Content -Encoding ascii '$dir\\run.env' \"$env_lines\"
schtasks /Create /TN MochiCheckRun /TR 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $dir\\tools\\run.ps1 -Exe $rel\\Mochi.exe -EnvFile $dir\\run.env' /SC ONCE /ST 23:59 /IT /F | Out-Null
schtasks /Run /TN MochiCheckRun | Out-Null
'started'" | tee -a "$out/summary.txt"
on_desktop MochiCheckWake "-File $dir\\tools\\wake.ps1" 5
sleep 15
shot start
if [ "$click" = 1 ]; then
  on_desktop MochiCheckClick "-File $dir\\tools\\click.ps1 -Folder $dir -Target mochi -Name popover" 20
  scp_from "$dir_fwd/shots/popover.png" "$out/shots/popover.png" 2>/dev/null && echo "  shots/popover.png" || echo "  (no popover screenshot)"
  on_desktop MochiCheckClick "-File $dir\\tools\\click.ps1 -Folder $dir -Target 1430,450 -Name after-popover" 20
fi
say "Sampling for $perf s"
sleep "$perf"
shot end
if [ "$screen_off" = 1 ]; then
  say "Letting the display sleep (1 minute), then sampling 150 s"
  vm_ps "powercfg /change monitor-timeout-ac 1" >/dev/null
  sleep 210
fi
vm_ps "Get-Content \"\$env:LOCALAPPDATA\\Mochi\\perf.log\" -ErrorAction SilentlyContinue" > "$out/perf.log" || true
say "Perf (the latest line per state)"
iconv -c -f UTF-8 -t ASCII//TRANSLIT < "$out/perf.log" | sed -E 's/ (A|\?|-) / | /g' | awk -F'perf: ' 'NF > 1 { split($2, a, " [0-9]+ s "); last[a[1]] = $2 } END { for (k in last) print "perf: " last[k] }' | sort | tee -a "$out/summary.txt"
say "Done: $out"
