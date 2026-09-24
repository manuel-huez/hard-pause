#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v cargo >/dev/null 2>&1; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi
bash scripts/check-swift-deprecations.sh
xcrun swift-format lint --strict --recursive core/apple ios/App ios/Shared ios/Extensions ios/Tests ios/UITests macos/App macos/BrowserWorker macos/Core macos/Service macos/CLI macos/Tests macos/ServiceTests
cargo fmt --manifest-path core/rust/Cargo.toml --check
cargo clippy --manifest-path core/rust/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path core/rust/Cargo.toml --locked
xcodegen generate --spec ios/project.yml
xcodegen generate --spec macos/project.yml
python3 scripts/check-project-settings.py
python3 scripts/test_project_settings.py
xcodebuild -project macos/HardPause.xcodeproj -scheme HardPause -destination 'platform=macOS' -derivedDataPath build/macos CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES test
device_id=$(python3 scripts/select-simulator.py)
xcodebuild -project ios/HardPause.xcodeproj -scheme HardPause -destination "platform=iOS Simulator,id=$device_id" -derivedDataPath build/ios CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- SWIFT_TREAT_WARNINGS_AS_ERRORS=YES test
xcodebuild -project ios/HardPause.xcodeproj -scheme HardPause -destination 'generic/platform=iOS' -derivedDataPath build/ios-device CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
