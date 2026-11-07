#!/bin/bash
# Cuts a release of Mochi for Windows and publishes it on your own Mochi Link relay, where installed copies find it
# within 6 hours (docs/SPRINT_2.md W29; the relay's README, "App updates"). Nothing is public: only devices of a room
# on your relay can download it.
#
#   scripts/release-windows.sh <version> [--notes "What's new"] [--notes-file FILE] [--channel windows|windows-test]
#                                        [--github] [--skip-build] [--dry-run]
#
#   1. Sets the version in flutter/apps/mochi_desktop (pubspec.yaml, lib/src/desktop.dart): a new version gets the next
#      build number, the same version keeps its own (so running it again changes nothing). On the first run it also
#      makes the release key and puts its public half in lib/src/update/update_keys.dart. Commits that.
#   2. Sends `git archive HEAD flutter link-spec` (no ._ files) to the Windows VM and builds
#      `flutter build windows --release` there.
#   3. Zips the Release folder with the VC++ runtime next to Mochi.exe (x64, from Visual Studio's redist folder: on an
#      ARM PC, System32's copies are ARM64): Mochi-<version>-windows-x64.zip.
#   4. Back here: the zip's SHA-256, the manifest, and its Ed25519 signature made with the key in your login Keychain
#      (service mochi-windows-update-signing). The private key is never printed, written to a file or put in the app.
#   5. Uploads the zip, manifest.sig and manifest.json (with the signature as its KV metadata) to the relay's UPDATES
#      KV namespace, the manifest last. --channel windows-test publishes to the test feed instead (a copy started with
#      MOCHI_UPDATE_CHANNEL=windows-test reads it).
#   6. --github: a prerelease on the private repo, for downloading by hand (the commit must be pushed first).
#
#   --dry-run    everything except the commit and the uploads, signed with a throwaway Keychain key
#                (mochi-windows-update-signing-dryrun) whose public half goes only into the copy that's built; the
#                upload commands are printed instead.
#   --skip-build reuses the zip already in build/windows-release/<version> (to publish again, or to GitHub).
#
# Environment (defaults in brackets): MOCHI_VM [rizz@192.168.64.2], MOCHI_VM_KEY [~/.ssh/mochi_windows_vm],
# MOCHI_VM_DIR [C:\src\mochi], MOCHI_LINK_DIR [~/Documents/developer/mochi-link], MOCHI_SIGNING_SERVICE.
set -euo pipefail

usage() {
  sed -n '6,7p' "$0" | sed 's/^#   //' >&2
  exit 64
}

[ $# -ge 1 ] || usage
version="$1"
shift
notes=""
notes_file=""
channel="windows"
github=0
skip_build=0
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) notes="$2"; shift 2 ;;
    --notes-file) notes_file="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    --github) github=1; shift ;;
    --skip-build) skip_build=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    *) usage ;;
  esac
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-windows: the version is like 0.2.0" >&2; exit 64; }
case "$channel" in windows|windows-test) ;; *) echo "release-windows: --channel is windows or windows-test" >&2; exit 64 ;; esac

vm="${MOCHI_VM:-rizz@192.168.64.2}"
vm_key="${MOCHI_VM_KEY:-$HOME/.ssh/mochi_windows_vm}"
vm_dir="${MOCHI_VM_DIR:-C:\\src\\mochi}"
link_dir="${MOCHI_LINK_DIR:-$HOME/Documents/developer/mochi-link}"
default_service="mochi-windows-update-signing"
if [ "$dry_run" = 1 ]; then service="${MOCHI_SIGNING_SERVICE:-$default_service-dryrun}"; else service="${MOCHI_SIGNING_SERVICE:-$default_service}"; fi
github_repo="rizulsharma-2003/tamagotchi"
github_user="rizulsharma-2003"
wrangler="wrangler@4.151.3"

repo="$(cd "$(dirname "$0")/.." && pwd)"
app="$repo/flutter/apps/mochi_desktop"
pubspec="$app/pubspec.yaml"
desktop_dart="$app/lib/src/desktop.dart"
keys_dart="$app/lib/src/update/update_keys.dart"
zip_name="Mochi-$version-windows-x64.zip"
out="$repo/build/windows-release/$version"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say() { printf '\n== %s\n' "$*"; }
die() { echo "release-windows: $*" >&2; exit 1; }
signing() { (cd "$app" && dart tool/update_signing.dart "$@"); }
ssh_vm() { ssh -i "$vm_key" -o BatchMode=yes -o ConnectTimeout=15 "$vm" "$@"; }
# Runs a PowerShell script on the VM (as -EncodedCommand: no quoting surprises), with Flutter and Git on its PATH.
vm_ps() {
  local script
  script="\$ErrorActionPreference = 'Stop'; \$ProgressPreference = 'SilentlyContinue'
\$env:Path = 'C:\\src\\flutter\\bin;C:\\Program Files\\Git\\cmd;' + \$env:Path
$1"
  ssh_vm "powershell -NoProfile -NonInteractive -EncodedCommand $(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
}
# Rewrites the version and the public key in a copy of mochi_desktop (the repo's own, or the one sent to the VM).
stamp() {
  local root="$1"
  sed -i '' -E "s/^version: .*/version: $version+$build/" "$root/pubspec.yaml"
  sed -i '' -E "s/^const String appVersion = '.*';/const String appVersion = '$version';/" "$root/lib/src/desktop.dart"
  sed -i '' -E "s/^const int appBuild = [0-9]+;/const int appBuild = $build;/" "$root/lib/src/desktop.dart"
  sed -i '' -E "s/^const String windowsUpdatePublicKey = '.*';/const String windowsUpdatePublicKey = '$public_key';/" "$root/lib/src/update/update_keys.dart"
}

command -v dart >/dev/null || die "dart isn't on PATH (Flutter's bin folder)."
[ "$dry_run" = 1 ] && echo "Dry run: no commit, no uploads, a throwaway signing key ($service)."

# 1. The version, the build number and the release key.
say "Version"
current="$(sed -n -E 's/^version: ([0-9.]+)\+([0-9]+)$/\1 \2/p' "$pubspec")"
[ -n "$current" ] || die "pubspec.yaml has no version like 0.1.0+1."
current_version="${current% *}"
current_build="${current#* }"
if [ "$current_version" = "$version" ]; then build="$current_build"; else build=$((current_build + 1)); fi
echo "Mochi for Windows $version (build $build); the repo had $current_version (build $current_build)."

public_key="$(signing ensure-key --service "$service")"
[[ "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "the release key's public half doesn't look right."
app_key="$(sed -n -E "s/^const String windowsUpdatePublicKey = '(.*)';$/\1/p" "$keys_dart")"
if [ "$dry_run" = 0 ] && [ -n "$app_key" ] && [ "$app_key" != "$public_key" ]; then
  die "the app's release key (update_keys.dart) isn't the one in your Keychain ($service): installed copies would refuse this release."
fi
echo "Release key (public): $public_key"

if [ "$dry_run" = 0 ]; then
  if [ -n "$(git -C "$repo" status --porcelain -- flutter link-spec)" ]; then
    die "flutter/ or link-spec/ has uncommitted changes. Commit them first: the release is built from HEAD."
  fi
  stamp "$app"
  if [ -n "$(git -C "$repo" status --porcelain -- flutter)" ]; then
    git -C "$repo" add -- "$pubspec" "$desktop_dart" "$keys_dart"
    git -C "$repo" commit -q -m "Mochi for Windows $version (build $build)" -- "$pubspec" "$desktop_dart" "$keys_dart"
    echo "Committed $(git -C "$repo" rev-parse --short HEAD): Mochi for Windows $version (build $build)."
  else
    echo "Already at $version (build $build) in HEAD."
  fi
elif [ -n "$(git -C "$repo" status --porcelain -- flutter link-spec)" ]; then
  echo "Note: uncommitted changes in flutter/ or link-spec/ are not in the build (it's made from HEAD)."
fi

# 2–3. Build on the VM and zip it with the VC++ runtime.
zip="$out/$zip_name"
# What the zip was built with: a zip whose key or build number isn't this run's is never published.
stamp_line="build $build key $public_key"
if [ "$skip_build" = 1 ]; then
  [ -f "$zip" ] || die "--skip-build: there's no $zip yet."
  [ "$(cat "$out/built-with" 2>/dev/null)" = "$stamp_line" ] ||
    die "--skip-build: $zip_name was built with another key or build number. Build it again (without --skip-build)."
  say "Using the zip already built"
else
  say "Sending the source to $vm ($vm_dir)"
  mkdir -p "$work/src"
  COPYFILE_DISABLE=1 git -C "$repo" archive --format=tar HEAD flutter link-spec | tar -xf - -C "$work/src"
  stamp "$work/src/flutter/apps/mochi_desktop"
  find "$work/src" -name '._*' -delete
  COPYFILE_DISABLE=1 tar -cf "$work/mochi-src.tar" -C "$work/src" flutter link-spec
  vm_tar="${vm_dir}-src.tar"
  scp -i "$vm_key" -o BatchMode=yes -q "$work/mochi-src.tar" "$vm:${vm_tar//\\//}"
  vm_ps "
New-Item -ItemType Directory -Force -Path '$vm_dir' | Out-Null
tar.exe -xf '$vm_tar' -C '$vm_dir'
if (\$LASTEXITCODE -ne 0) { throw 'Unpacking the source failed.' }
Get-ChildItem -Path '$vm_dir' -Recurse -Force -Filter '._*' -ErrorAction SilentlyContinue | Remove-Item -Force
Remove-Item '$vm_tar'
'Unpacked.'"

  say "Building on the VM (flutter build windows --release; the whole log goes to $out/build.log)"
  if ! vm_ps "
Set-Location '$vm_dir\\flutter\\apps\\mochi_desktop'
cmd /c 'flutter build windows --release 2>&1'
if (\$LASTEXITCODE -ne 0) { throw \"flutter build windows failed (\$LASTEXITCODE).\" }" > "$out/build.log" 2>&1; then
    tail -30 "$out/build.log" >&2
    die "the build failed (the whole log: $out/build.log)."
  fi
  grep -E 'Building Windows application|Built ' "$out/build.log" || true

  say "Zipping with the VC++ runtime"
  vm_ps "
function Machine(\$path) { \$bytes = [IO.File]::ReadAllBytes(\$path); \$pe = [BitConverter]::ToInt32(\$bytes, 60); [BitConverter]::ToUInt16(\$bytes, \$pe + 4) }
\$release = '$vm_dir\\flutter\\apps\\mochi_desktop\\build\\windows\\x64\\runner\\Release'
foreach (\$file in 'Mochi.exe', 'mochi_hook.exe', 'flutter_windows.dll', 'data\\app.so', 'data\\icudtl.dat') {
  if (-not (Test-Path \"\$release\\\$file\")) { throw \"The build has no \$file.\" }
}
foreach (\$file in 'Mochi.exe', 'mochi_hook.exe') {
  if ((Machine \"\$release\\\$file\") -ne 0x8664) { throw \"\$file isn't an x64 program.\" }
}
\$out = '$vm_dir\\release'
if (Test-Path \$out) { Remove-Item -Recurse -Force \$out }
\$stage = \"\$out\\Mochi\"
New-Item -ItemType Directory -Force -Path \$stage | Out-Null
Copy-Item -Recurse -Force \"\$release\\*\" \$stage
\$crt = Get-ChildItem 'C:\\Program Files*\\Microsoft Visual Studio\\*\\*\\VC\\Redist\\MSVC\\*\\x64\\Microsoft.VC14*.CRT' -Directory -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
foreach (\$dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  \$from = \$null
  if (\$crt -and (Test-Path \"\$(\$crt.FullName)\\\$dll\")) { \$from = \"\$(\$crt.FullName)\\\$dll\" }
  elseif ((Test-Path \"C:\\Windows\\System32\\\$dll\") -and ((Machine \"C:\\Windows\\System32\\\$dll\") -eq 0x8664)) { \$from = \"C:\\Windows\\System32\\\$dll\" }
  if (-not \$from) { throw \"No x64 \$dll on the VM: install Visual Studio's x64 build tools.\" }
  if ((Machine \$from) -ne 0x8664) { throw \"\$from isn't x64.\" }
  Copy-Item -Force \$from \$stage
  \"VC++ runtime: \$from\"
}
tar.exe -a -c -f \"\$out\\$zip_name\" -C \$out Mochi
if (\$LASTEXITCODE -ne 0) { throw 'Zipping failed.' }
'Zipped: ' + (Get-Item \"\$out\\$zip_name\").Length + ' bytes'"

  vm_zip="$vm_dir\\release\\$zip_name"
  scp -i "$vm_key" -o BatchMode=yes -q "$vm:${vm_zip//\\//}" "$zip"
  printf '%s\n' "$stamp_line" > "$out/built-with"
fi

# 4. Checksum, manifest, signature.
say "Signing"
size="$(stat -f%z "$zip")"
sha256="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
if [ -n "$notes_file" ]; then cp "$notes_file" "$work/notes.txt"; else printf '%s' "$notes" > "$work/notes.txt"; fi
signing manifest --version "$version" --build "$build" --file "$zip_name" --size "$size" --sha256 "$sha256" \
  --notes-file "$work/notes.txt" --min-windows 10.0.17763 --out "$out/manifest.json"
signing sign --service "$service" --manifest "$out/manifest.json" --out "$out/manifest.sig"
# The key compiled into this very build must accept it (or the release would be refused everywhere).
signing verify --manifest "$out/manifest.json" --signature "$out/manifest.sig" --public-key "$public_key" >/dev/null
signature="$(tr -d '\n' < "$out/manifest.sig")"
echo "$zip_name: $size bytes, SHA-256 $sha256"
echo "Signed: $out/manifest.json, $out/manifest.sig"
# Unpacked the way the app unpacks it: a whole x64 Mochi with the VC++ runtime.
signing check-zip --zip "$zip" --manifest "$out/manifest.json"

# 5. Publish on the relay (the manifest last, so nobody sees it before its zip).
say "Publishing to the relay ($channel)"
upload=(
  "kv key put --binding UPDATES --remote $channel/$zip_name --path $zip"
  "kv key put --binding UPDATES --remote $channel/manifest.sig --path $out/manifest.sig"
  "kv key put --binding UPDATES --remote $channel/manifest.json --path $out/manifest.json --metadata {\"sig\":\"$signature\"}"
)
if [ "$dry_run" = 1 ]; then
  for command in "${upload[@]}"; do echo "would run (in $link_dir): npx --yes $wrangler $command"; done
else
  grep -q '"UPDATES"' "$link_dir/wrangler.jsonc" ||
    die "the relay has no UPDATES namespace yet: in $link_dir run npx --yes $wrangler kv namespace create mochi-updates --binding UPDATES --update-config, then deploy."
  (
    cd "$link_dir"
    npx --yes "$wrangler" kv key put --binding UPDATES --remote "$channel/$zip_name" --path "$zip"
    npx --yes "$wrangler" kv key put --binding UPDATES --remote "$channel/manifest.sig" --path "$out/manifest.sig"
    npx --yes "$wrangler" kv key put --binding UPDATES --remote "$channel/manifest.json" --path "$out/manifest.json" \
      --metadata "{\"sig\":\"$signature\"}"
  )
  echo "Published. Installed copies on the $channel feed pick it up within 6 hours (or at Check for Updates)."
fi

# 6. A prerelease on GitHub, for downloading by hand.
if [ "$github" = 1 ]; then
  say "GitHub prerelease"
  tag="windows-v$version"
  commit="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" fetch -q origin 2>/dev/null || true
  if [ "$dry_run" = 1 ]; then
    echo "would run: gh release create $tag $zip manifest.json manifest.sig --repo $github_repo --prerelease --target $commit"
  elif ! git -C "$repo" branch -r --contains "$commit" 2>/dev/null | grep -q .; then
    echo "Skipped: $commit isn't pushed yet. Push it, then run this again with --skip-build --github."
  else
    GH_TOKEN="$(gh auth token --user "$github_user")"
    export GH_TOKEN
    if gh release view "$tag" --repo "$github_repo" >/dev/null 2>&1; then
      gh release upload "$tag" "$zip" "$out/manifest.json" "$out/manifest.sig" --repo "$github_repo" --clobber
    else
      gh release create "$tag" "$zip" "$out/manifest.json" "$out/manifest.sig" --repo "$github_repo" --prerelease \
        --target "$commit" --title "Mochi for Windows $version" --notes-file "$work/notes.txt"
    fi
    echo "https://github.com/$github_repo/releases/tag/$tag"
  fi
fi

say "Done"
echo "$out"
