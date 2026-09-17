# Hard Pause for iOS

Native SwiftUI app for local Screen Time blocking. It uses `FamilyControls`,
`ManagedSettings`, `ManagedSettingsUI`, and `DeviceActivity`; it has no server,
account, analytics, or sync code.

The app and monitor use the same [lifecycle core](../core/) as macOS. Home, Plans,
and Settings follow the Mac app's design, with native iOS selection and setup.
Existing saved blocks keep their rules and waiting periods.

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
- Activation saves an intent before applying new restrictions, then saves the
  primary collection before allowing relaxation. App and monitor serialize this
  work through one coordinated file. Interrupted activation resumes from its
  saved base and candidate; a stale intent cannot replay an old open break.
- Waits use a continuous clock, including time asleep, to resist wall-clock changes.
  After a reboot, they resume without credit for time powered off.
- A missing or unavailable schedule keeps its pause blocked. Schedule-limit errors
  do not relax existing rules. Recovery stores one aggregate snapshot of all active
  pauses, and the original single-pause state migrates on first reconciliation.

## Protection setup

New blocks enable app-removal protection by default, with a visible explanation.
It prevents deletion of **all apps**, including Hard Pause. The choice is frozen
when the block starts and remains in force during breaks and unlock waits.
Automatic date/time protection is also device-wide.

App deletion protection does not require a passcode. As an optional extra on iOS
26.4 or later, set a system Screen Time passcode in Settings → Screen Time →
Lock Screen Time Settings to protect permission changes. Hard Pause cannot set,
read or confirm that passcode. This follows [Opal's current setup guidance](https://opalapp.com/help/how-can-i-make-opal-foolproof).
The native controls are Apple's [`denyAppRemoval`](https://developer.apple.com/documentation/managedsettings/applicationsettings/denyappremoval-swift.property)
and `requireAutomaticDateAndTime`; no private Settings links or device-management
profile are used.

Opal also documents an older [Shortcuts-based Settings redirect](https://opalapp.com/help/how-to-lock-opals-screen-time-access).
That is a user-created automation, separate from native app-removal protection;
Hard Pause does not install or require such an automation.

## Device release checks

Run on a signed iPhone with Family Controls and the shared App Group enabled for
the app and all three extensions. Test on the minimum supported OS and the current
OS before release. Device enforcement is not covered by simulator tests.

- Authorize Screen Time, select real apps/categories/sites, activate a block and
  check each selected target. Check manual domains and Apple's adult filter.
- Request a break, close the app, lock the phone, and check both delayed opening
  and relocking. Repeat with two overlapping blocks and a full-unlock request.
- During a block, a break and a pending unlock, check that app deletion and manual
  date/time changes remain restricted when enabled. After the last block ends,
  check that Hard Pause's restrictions clear without changing another app's rules.
- Restart the phone during a waiting period and a break. Check that no unverified
  time is credited and opening the app preserves saved commitments.
- On a dedicated test device, test authorization loss and reapproval, missing or
  delayed monitor callbacks, and schedule-limit failures. Do not use a live
  personal commitment for these checks.
- Set a Screen Time passcode and check the OS's permission-change prompt. Record
  the OS version and result; the app must never report the passcode as verified.

Unsigned device compilation: `xcodebuild -project ios/HardPause.xcodeproj -scheme HardPause -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` from the repository root. A physical installation additionally needs the developer team and provisioning profiles.
