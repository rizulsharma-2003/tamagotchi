#!/bin/bash
# Builds MacTamagotchi.app with the installed Swift toolchain.
#
#   scripts/build-app.sh                 # release build → build/MacTamagotchi.app
#   scripts/build-app.sh --install       # …and copy it to ~/Applications
#   UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#   TEAM_ID=… MAC_PROFILE=….provisionprofile SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#                                        # optional: team-signed with the team's development profile embedded.
#
# No signing option is needed for any feature: the phones link through Mochi Link (pairing by QR code), and the
# relay holds the push key, so the app carries no iCloud entitlement, no provisioning profile and no push key.
# Without SIGN_IDENTITY the build is signed ad hoc ("-").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-dev.mactamagotchi.MacTamagotchi}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
TEAM_ID="${TEAM_ID:-}"
MAC_PROFILE="${MAC_PROFILE:-}"
OUT="$ROOT/build"
APP="$OUT/MacTamagotchi.app"

cd "$ROOT"
ARCH_FLAGS=(--arch arm64)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "==> swift build -c $CONFIG ${ARCH_FLAGS[*]}"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product MacTamagotchi
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product mactamagotchi-hook
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/MacTamagotchi" "$APP/Contents/MacOS/MacTamagotchi"
cp "$BIN/mactamagotchi-hook" "$APP/Contents/Helpers/mactamagotchi-hook"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>MacTamagotchi</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>MacTamagotchi</string>
    <key>CFBundleDisplayName</key><string>MacTamagotchi</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSMicrophoneUsageDescription</key><string>Mochi listens only while you hold the Ask Mochi shortcut, and turns your words into text on this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Your spoken requests to Mochi are turned into text on this Mac.</string>
    <key>NSHumanReadableCopyright</key><string>MacTamagotchi — a personal companion app. Mochi is an original character; the companion is drawn after the Claude Code mascot.</string>
</dict>
</plist>
PLIST

echo "==> Rendering app icon"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
"$APP/Contents/MacOS/MacTamagotchi" --render-iconset "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Building the widget extension"
# WidgetKit extensions can't be built by SwiftPM; compile the single file directly. The extension
# is sandboxed and may only read the folder the app publishes its status to.
APPEX="$APP/Contents/PlugIns/MacTamagotchiWidgets.appex"
mkdir -p "$APPEX/Contents/MacOS"
WIDGET_ARCHS=(arm64)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then WIDGET_ARCHS=(arm64 x86_64); fi
WIDGET_SLICES=()
for arch in "${WIDGET_ARCHS[@]}"; do
    xcrun swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos14.0" -sdk "$(xcrun --show-sdk-path)" \
        -module-name MacTamagotchiWidgets "$ROOT/Widget/MacTamagotchiWidgets.swift" -o "$OUT/MacTamagotchiWidgets-$arch"
    WIDGET_SLICES+=("$OUT/MacTamagotchiWidgets-$arch")
done
lipo -create "${WIDGET_SLICES[@]}" -output "$APPEX/Contents/MacOS/MacTamagotchiWidgets"
rm -f "${WIDGET_SLICES[@]}"
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>MacTamagotchi</string>
    <key>CFBundleExecutable</key><string>MacTamagotchiWidgets</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}.Widgets</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>MacTamagotchiWidgets</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST
cat > "$OUT/widget.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
    <array><string>/Library/Application Support/MacTamagotchi/Widget/</string></array>
</dict>
</plist>
PLIST

# The app and team identifiers are restricted entitlements: claimed only with a profile that allows them, or macOS
# refuses to launch the app. Nothing in the app needs them; they keep the team-signed build like the ones before.
TEAM_ENTITLEMENTS=""
if [[ -n "$TEAM_ID" && -n "$MAC_PROFILE" ]]; then
    [[ -f "$MAC_PROFILE" ]] || { echo "MAC_PROFILE not found: $MAC_PROFILE" >&2; exit 1; }
    cp "$MAC_PROFILE" "$APP/Contents/embedded.provisionprofile"
    TEAM_ENTITLEMENTS="<key>com.apple.application-identifier</key><string>${TEAM_ID}.${BUNDLE_ID}</string>
    <key>com.apple.developer.team-identifier</key><string>${TEAM_ID}</string>"
    echo "==> Team-signed with $(basename "$MAC_PROFILE")"
elif [[ -n "$TEAM_ID" || -n "$MAC_PROFILE" ]]; then
    echo "==> TEAM_ID and MAC_PROFILE go together; signing without a profile"
fi
cat > "$OUT/app.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
    ${TEAM_ENTITLEMENTS}
</dict>
</plist>
PLIST

echo "==> Signing (${SIGN_IDENTITY})"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/mactamagotchi-hook"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" --entitlements "$OUT/widget.entitlements" "$APPEX"
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" --entitlements "$OUT/app.entitlements" "$APP"
codesign --verify --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    rm -rf "$DEST/MacTamagotchi.app"
    cp -R "$APP" "$DEST/"
    # Let the system know about the widget extension inside.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/MacTamagotchi.app" || true
    pluginkit -a "$DEST/MacTamagotchi.app/Contents/PlugIns/MacTamagotchiWidgets.appex" || true
    echo "==> Installed to $DEST/MacTamagotchi.app"
fi

echo "==> Done: $APP"
