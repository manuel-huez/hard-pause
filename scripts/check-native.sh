#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift-format lint --strict --recursive core/Sources core/Tests ios/App ios/Shared ios/Extensions ios/Tests ios/UITests macos/App macos/Core macos/Service macos/CLI macos/Tests macos/ServiceTests
swift test --package-path core
xcodegen generate --spec ios/project.yml
xcodegen generate --spec macos/project.yml
python3 scripts/check-project-settings.py
python3 scripts/test_project_settings.py
xcodebuild -project macos/HardPause.xcodeproj -scheme HardPause -destination 'platform=macOS' -derivedDataPath build/macos CODE_SIGNING_ALLOWED=NO test
device_id=$(python3 scripts/select-simulator.py)
xcodebuild -project ios/HardPause.xcodeproj -scheme HardPause -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath build/ios CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
xcodebuild -project ios/HardPause.xcodeproj -scheme HardPause -destination 'generic/platform=iOS' -derivedDataPath build/ios-device CODE_SIGNING_ALLOWED=NO build
