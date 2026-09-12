# Hard Pause for iOS

Native SwiftUI foundation for local Screen Time blocking. It uses `FamilyControls`,
`ManagedSettings`, `ManagedSettingsUI`, and `DeviceActivity`; it has no server,
account, analytics, or sync code.

## Run

1. Install XcodeGen and run `xcodegen generate` in this folder.
2. Set a Development Team for all four product targets.
3. Register `group.com.hardpause.shared` for the app and extensions, or change the
   identifier in `project.yml`, every entitlements file, and
   `Shared/HardPauseConstants.swift`.
4. Add the Family Controls capability to every product identifier. Distribution
   builds need Apple approval for the Family Controls entitlement.
5. Build on a physical iPhone. Simulator tests cover the interface and local state
   logic. Screen Time enforcement and extension callbacks have not yet been verified
   on a physical device.

## Local mascot and signing

The character uses `web/mascot/` in a nonpersistent `WKWebView`; controls and enforcement remain native. XcodeGen bundles the entire folder, including `native.html`, JavaScript, CSS, and the MIT license and attribution notices. No remote content is needed.

Simulator builds and tests do not need paid signing. A free Personal Team is not enough to provision the full Family Controls/App Groups device build. Use the required program membership and capabilities for physical-device enforcement tests; distribution entitlement approval is a separate step. See [Apple’s capability table](https://developer.apple.com/help/account/reference/supported-capabilities-ios).

## Enforcement limits

- Each named pause has its own fixed active snapshot, `ManagedSettingsStore`, and
  `DeviceActivityMonitor` schedule. Inactive pauses can be renamed, edited, or
  deleted. No more than 16 pauses can be active at one time.
- Timeout and full-unlock requests have separate delays. A timeout opens for its
  configured length and then relocks. An optional fixed elapsed duration ends the
  pause even when another request is pending.
- Restrictions from overlapping pauses form a union. A timeout for one pause does
  not open a target that another pause still blocks.
- App-removal and automatic-date protection are device-wide. They remain enabled
  when any active pause requires them, including while another pause has a timeout.
- Automatic adult-site filtering uses Apple's `.auto` web filter. Apple controls
  classification and browser coverage. Manual domains and Screen Time website
  selections are also supported.
- iOS owns Family Controls permission. A user may be able to revoke it in Settings.
  Hard Pause cannot configure or verify a Screen Time passcode. Passcode protection
  differs by iOS version and must be tested on the target device.
- Waits use a continuous clock, including time asleep, to resist wall-clock changes.
  After a reboot, they resume without credit for time powered off.
- A missing or unavailable schedule keeps its pause blocked. Schedule-limit errors
  do not relax existing rules. Recovery stores one aggregate snapshot of all active
  pauses, and the original single-pause state migrates on first reconciliation.
