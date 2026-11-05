#!/bin/sh
# Builds the Claude Code hook helper (packages/mochi_wire/bin/mochi_hook.dart) for this computer and puts it next to
# the macOS development build of Mochi (Mochi.app/Contents/MacOS/mochi_hook), where "Connect Claude Code" finds it.
# The Windows build does the same in windows/CMakeLists.txt.
#
#   tool/build_hook.sh [debug|release]
set -eu
cd "$(dirname "$0")/.."
mode="${1:-debug}"
case "$mode" in debug) folder=Debug ;; release) folder=Release ;; *) echo "usage: $0 [debug|release]" >&2; exit 64 ;; esac
mkdir -p build
dart compile exe ../../packages/mochi_wire/bin/mochi_hook.dart -o build/mochi_hook
app="build/macos/Build/Products/$folder/Mochi.app"
if [ -d "$app" ]; then
  cp build/mochi_hook "$app/Contents/MacOS/mochi_hook"
  # Re-sign the bundle with an ad-hoc signature now that it has a new file inside.
  codesign --force --sign - "$app/Contents/MacOS/mochi_hook" >/dev/null
  codesign --force --sign - --preserve-metadata=entitlements "$app" >/dev/null 2>&1 || true
  echo "mochi_hook -> $app/Contents/MacOS/mochi_hook"
else
  echo "mochi_hook -> build/mochi_hook (build the app first to put it inside Mochi.app)"
fi
