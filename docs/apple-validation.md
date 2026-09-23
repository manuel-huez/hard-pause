# Apple implementation validation

Checked locally on 2026-09-17 with Xcode 26.6.

## Delivered

- One Swift lifecycle and elapsed-time core compiled into both Apple apps and the Mac service. Native storage and enforcement remain platform-specific.
- Existing Mac plans retain their behavior. A differential test compares the former Mac lifecycle with the shared implementation. New Pause/Hard Pause mode controls are shared in meaning across both apps.
- iOS Home, Plans, Settings and plan editor aligned with Mac, including pending-break cancellation and commitment guidance before full unlock.
- Native iOS app-deletion and automatic-date protection remain enabled through breaks and pending unlocks when selected. New policies enable deletion protection by default; saved opt-outs remain unchanged.
- Durable iOS activation intent, conservative recovery, storage validation and regression tests for interrupted activation and failed writes. No installed Mac service was changed.
- Hard Pause has no breaks or automatic end. iOS requires native deletion/date controls. Mac requires completed Screen Time code setup before activation.
- Mac code setup saves and reads back a System Keychain credential before native entry. Interrupted operations keep the same code. Release requires both its wait and all Mac plans inactive; activation and release are serialized. Pending setup cannot discard its code.
- Mac native Settings automation is experimental. It stops at unknown screens or Apple recovery prompts. No real code change or Keychain write was performed during validation.
- A portable adult-domain parser and reviewed supplement format support the existing Mac list. iOS uses Apple's native adult filter. No cross-device domain or plan sync is implemented.

## Local checks

| Check                                          | Result                                    | Log under `build/validation/` or command                                |
| ---------------------------------------------- | ----------------------------------------- | ----------------------------------------------------------------------- |
| Shared core fixtures                           | 9 tests passed                            | `core-current.log`                                                      |
| Mac app/core and service                       | 164 tests passed                          | `macos-current.log`                                                     |
| iOS unit and recovery tests                    | 116 tests passed                          | `ios-unit-current.log`                                                  |
| iOS navigation and editor UI                   | 1 test passed; ten screenshots reviewed   | `ios-mode-ui-current.log`, `ios-mode-screenshots/`                      |
| Native project settings                        | 7 tests passed; capability mappings valid | `scripts/check-project-settings.py`, `scripts/test_project_settings.py` |
| Repository formatting, lint and web unit tests | 24 tests passed                           | `repository-current.log`                                                |
| iPhone app and three extensions                | Unsigned device build passed              | `ios-device-current.log`                                                |

Run `scripts/check-native.sh` to repeat the shared-core, project, Mac, iOS and device-build checks. The iOS scheme also includes a Simulator UI navigation test with screenshot attachments. Simulator screenshots and XCUITest can run while the Mac desktop is locked.

## Physical-device gate

No iPhone was connected. The real Mac Screen Time code-entry/recovery/release flow and System Keychain daemon access remain unverified. Existing Screen Time controls and Apple account recovery can prevent or undo setup; the app must not claim verified iPhone protection from a Mac toggle.

Signed-device Screen Time enforcement, background transitions, deletion prevention, permission revocation/reapproval and passcode behavior remain unverified. The unsigned build cannot prove these features or replace a provisioned device build. Follow the [device release checks](../ios/README.md#device-release-checks).

App-removal protection does not require a passcode. Opal documents [native session removal protection](https://opalapp.com/help/what-is-app-uninstall-protection) separately from an optional iOS 26.4+ Screen Time passcode and an older [Shortcuts-based Settings redirect](https://opalapp.com/help/how-to-lock-opals-screen-time-access). Hard Pause uses native deletion/date controls; its passcode guidance is optional and does not claim to verify the OS setting.

Rust, Windows and Android remain outside this Apple implementation. See the [shared core](../core/README.md) for the current scope.

## 2026-09-23 source check

- Mac active plans can add rules without changing existing rules or waits. The service encrypts plan and Screen Time state with a System Keychain key; a separate Keychain anchor detects plan-state rollback. Inactive legacy state migrates on load.
- Xcode 27: 169 Mac tests, 10 shared-core tests, website checks, 14 browser tests, unsigned iPhone build, and signed Mac bundle validation passed.
- Local iOS simulator tests could not run because this Mac has no compatible iPhone simulator. Physical iPhone enforcement and signed Mac service Keychain access still need live validation. No installed service or active protection was changed.
