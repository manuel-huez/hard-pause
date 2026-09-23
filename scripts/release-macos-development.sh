#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo='manuel-huez/hard-pause'
expected_public_key='hqO11mB5r81uup2mbAJ1oYRwbVbEFxczONdXHFZVD8U='
team='ZBX6C7BJ5X'
account='hard-pause'
tag="${2:-}"
mode="${1:-}"

fail() { echo "$*" >&2; exit 1; }
[[ "$mode" == prepare || "$mode" == stage ]] || fail 'Usage: release-macos-development.sh prepare|stage vMAJOR.MINOR.PATCH'
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Tag must be vMAJOR.MINOR.PATCH'
[[ $# -eq 2 ]] || fail 'Expected exactly one mode and one tag'

out="$PWD/build/release-development/$tag"
app="$out/HardPause.xcarchive/Products/Applications/HardPause.app"
archive="$out/HardPause-macOS.zip"
feed="$out/appcast.xml"
packages="$PWD/build/release/packages"
signer="$packages/artifacts/sparkle/Sparkle/bin/sign_update"
keytool="$packages/artifacts/sparkle/Sparkle/bin/generate_keys"

verify_assets() {
    [[ -s "$archive" && -s "$feed" && -d "$app" && -s "$out/commit.txt" ]] || fail 'Prepared release assets are incomplete'
    /usr/bin/codesign --verify --deep --strict "$app"
    /usr/bin/unzip -tq "$archive" >/dev/null
    signature="$(python3 - "$feed" "$archive" "$tag" "$app" <<'PY'
import pathlib
import plistlib
import sys
import xml.etree.ElementTree as ET

feed, archive, tag, app = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4])
with (app / 'Contents/Info.plist').open('rb') as info_file:
    info = plistlib.load(info_file)
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
item = ET.parse(feed).find('./channel/item')
if item is None:
    raise SystemExit('Appcast has no update item')
if item.findtext(sparkle + 'version') != info.get('CFBundleVersion') or item.findtext(sparkle + 'shortVersionString') != tag[1:]:
    raise SystemExit('Appcast version does not match the app or tag')
enclosure = item.find('enclosure')
if enclosure is None or enclosure.get('url') != f'https://github.com/manuel-huez/hard-pause/releases/download/{tag}/HardPause-macOS.zip':
    raise SystemExit('Appcast download URL is wrong')
if enclosure.get('length') != str(archive.stat().st_size):
    raise SystemExit('Appcast archive size is wrong')
signature = enclosure.get(sparkle + 'edSignature')
if not signature:
    raise SystemExit('Appcast lacks EdDSA signature')
print(signature)
PY
)"
    "$signer" --verify --account "$account" "$archive" "$signature" >/dev/null
}

if [[ "$mode" == prepare ]]; then
    [[ -z "$(git status --porcelain)" ]] || fail 'Commit all source and project changes before preparing a release'
    [[ ! -e "$out" ]] || fail "Output already exists: $out"
    command -v xcodegen >/dev/null || fail 'xcodegen is required'
    command -v xcodebuild >/dev/null || fail 'Xcode is required'
    xcodegen generate --spec macos/project.yml
    [[ -z "$(git status --porcelain)" ]] || fail 'Generated Xcode project differs from the committed source'
    xcodebuild -resolvePackageDependencies -project macos/HardPause.xcodeproj -scheme HardPause -clonedSourcePackagesDirPath "$packages" -quiet
    [[ -x "$signer" && -x "$keytool" ]] || fail 'Pinned Sparkle signing tools are unavailable'
    public_key="$("$keytool" --account "$account" -p)"
    [[ "$public_key" == "$expected_public_key" ]] || fail 'Local Sparkle key differs from the release key'

    identity="$(security find-identity -v -p codesigning | sed -nE 's/^[[:space:]]*[0-9]+\) [[:xdigit:]]{40} "(Apple Development: [^"]+)".*$/\1/p')"
    [[ -n "$identity" && "$identity" != *$'\n'* ]] || fail 'Expected exactly one valid Apple Development identity'

    mkdir -p "$out"
    git rev-parse HEAD > "$out/commit.txt"
    xcodebuild -quiet archive \
        -project macos/HardPause.xcodeproj -scheme HardPause \
        -configuration Release -destination 'generic/platform=macOS' \
        -archivePath "$out/HardPause.xcarchive" \
        -clonedSourcePackagesDirPath "$packages" \
        CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" \
        CODE_SIGN_IDENTITY="$identity" \
        SPARKLE_EDDSA_PUBLIC_KEY="$public_key"

    [[ -d "$app" ]] || fail 'Archive has no app'
    plist="$app/Contents/Info.plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "${tag#v}" ]] || fail 'Tag and app version differ'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid app build number'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")" == "$public_key" ]] || fail 'App contains the wrong Sparkle key'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")" == "https://github.com/$repo/releases/latest/download/appcast.xml" ]] || fail 'App contains the wrong update feed URL'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$plist")" == false ]] || fail 'Silent updates must stay disabled'
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' "$plist")" == false ]] || fail 'Automatic installation must stay disabled'
    for code in "$app" "$app/Contents/Resources/hard-pause-service" "$app/Contents/Resources/hard-pause"; do
        /usr/bin/codesign --verify --deep --strict "$code"
        details="$(/usr/bin/codesign -dv --verbose=4 "$code" 2>&1)"
        [[ "$details" == *"Authority=$identity"* ]] || fail "Unexpected signing identity: $code"
        [[ "$details" == *"TeamIdentifier=$team"* ]] || fail "Unexpected signing team: $code"
    done
    /usr/bin/ditto -c -k --keepParent "$app" "$archive"
    "$signer" --account "$account" "$archive" > "$out/signature.txt"
    python3 scripts/release-macos-appcast.py --archive "$archive" --signature "$out/signature.txt" --app "$app" --tag "$tag" --output "$feed"
    verify_assets
    echo "Prepared development-signed assets in $out"
    exit 0
fi

[[ -x "$signer" ]] || fail 'Pinned Sparkle signing tool is unavailable'
verify_assets
build_commit="$(cat "$out/commit.txt")"
[[ "$build_commit" =~ ^[a-f0-9]{40}$ ]] || fail 'Invalid build commit marker'
remote_commit="$(git ls-remote origin "refs/tags/$tag^{}" | awk '{print $1}')"
if [[ -z "$remote_commit" ]]; then remote_commit="$(git ls-remote origin "refs/tags/$tag" | awk '{print $1}')"; fi
[[ "$remote_commit" == "$build_commit" ]] || fail 'Remote tag does not point to the prepared build commit'
[[ "$(gh repo view "$repo" --json nameWithOwner --jq '.nameWithOwner')" == "$repo" ]] || fail 'GitHub repository is unavailable'
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then fail 'Release already exists; inspect it before retrying'; fi
gh release create "$tag" --repo "$repo" --draft --verify-tag \
    --title "Hard Pause ${tag#v} (development signed)" \
    --notes 'Development-signed macOS build. Apple has not notarized it. macOS may require manual approval on first open. Automatic background updates are disabled; use Check for Updates.'
gh release upload "$tag" --repo "$repo" "$archive" "$feed"
[[ "$(gh release view "$tag" --repo "$repo" --json isDraft --jq '.isDraft')" == true ]] || fail 'Release is not a draft'
echo "Staged draft release: https://github.com/$repo/releases/tag/$tag"
