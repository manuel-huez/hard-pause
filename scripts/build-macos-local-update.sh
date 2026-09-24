#!/bin/bash
set -euo pipefail

[[ $# -eq 1 && "$1" =~ ^[1-9][0-9]{0,9}$ ]] || {
    echo 'Usage: scripts/build-macos-local-update.sh BUILD_NUMBER' >&2
    exit 64
}

cd "$(dirname "$0")/.."
build_number="$1"
output="$PWD/build/local-updates/$build_number"
archive="$output/HardPause.xcarchive"
app="$archive/Products/Applications/HardPause.app"
[[ ! -e "$output" ]] || { echo "Build already exists: $output" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo 'xcodegen is required' >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo 'Xcode is required' >&2; exit 1; }

identity="${HARD_PAUSE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning \
        | sed -nE 's/^[[:space:]]*[0-9]+\) [[:xdigit:]]{40} "(Apple Development: [^"]+)".*$/\1/p')"
fi
[[ -n "$identity" && "$identity" != *$'\n'* ]] || {
    echo 'Set HARD_PAUSE_SIGN_IDENTITY to one enrolled Apple Development identity.' >&2
    exit 1
}

xcodegen generate --spec macos/project.yml
mkdir -p "$output"
xcodebuild -quiet archive \
    -project macos/HardPause.xcodeproj -scheme HardPause \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$archive" \
    -derivedDataPath "$output/DerivedData" \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=ZBX6C7BJ5X \
    CODE_SIGN_IDENTITY="$identity" \
    CURRENT_PROJECT_VERSION="$build_number" \
    SPARKLE_EDDSA_PUBLIC_KEY='hqO11mB5r81uup2mbAJ1oYRwbVbEFxczONdXHFZVD8U='

[[ -d "$app" ]] || { echo 'Archive has no app.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$build_number" ]] \
    || { echo 'App build number does not match.' >&2; exit 1; }
"$app/Contents/Resources/service-dry-run.sh"
echo "Local update build: $app"
echo "Do not open this archive while Hard Pause is running; it does not replace the installed app."
echo "Use the installed app's signed update flow to update the GUI and service."
