# Hard Pause for macOS

Block selected apps and websites on your Mac, with a wait before access returns.
The SwiftUI app handles setup and browser controls. A local root service owns
saved plans, waiting periods, and system enforcement.

**In development:** this guide describes the source build, not the version installed
on your Mac. Real service, reboot, and Screen Time checks remain separate from
source tests.

The [early Mac download](https://github.com/manuel-huez/hard-pause/releases/latest)
is signed for development, not notarized by Apple. A new Mac may require manual
approval to open it. The installed version 2 service cannot be replaced while a
plan is active; see [updates](#updates).

## Requirements and build

- macOS 26.0 or later.
- Xcode with the macOS SDK selected with `SDKROOT=macosx`.
- XcodeGen.
- An Apple Development signing identity in the login keychain for local app builds.

Build from the repository root:

```sh
xcodegen generate --spec macos/project.yml
xcodebuild -project macos/HardPause.xcodeproj -scheme HardPause -configuration Release -destination 'platform=macOS' -derivedDataPath build/macos build
```

The project uses `Apple Development` signing. If needed, pass
`CODE_SIGN_IDENTITY='<certificate name or SHA-1>'`. Keep the same signing identity,
bundle ID, and app location across updates. Avoid `CODE_SIGN_IDENTITY=-`: ad-hoc
builds can reset macOS permissions. Signing does not grant permissions; setup
still needs approval. CI tests can use `CODE_SIGNING_ALLOWED=NO`.

The build produces `HardPause.app`, `hard-pause-service`, and the `hard-pause`
command-line client. Unit tests cover the app contracts, persistence, client
authentication, and enforcement logic.

Public distribution needs Developer ID signing and Apple notarization. The
installer rejects unsigned apps. Use certificate signing for local builds to keep
permissions stable across updates.

For a local test update, run `scripts/build-macos-local-update.sh BUILD_NUMBER`
from the repository root. Use a number above the installed app build, then open
the signed app printed by the script. This uses the same development identity
and does not need a GitHub release or notarization. A service with handoff
support can install the newer local build without another administrator prompt.
The installed v2 service still needs its first migration after all blocks end.

## Local installation

On first launch, complete the setup in the app:

1. Select **Install protection** and approve the standard macOS administrator prompt. The app never handles the password.
2. Select **Allow access** for each installed browser. Keep the browser open and approve the macOS permission request. If access was denied, Hard Pause opens the permission pane. The app detects the approval.
3. Enable **Start at login**.

The normal setup does not require finding app files or using Terminal. Readiness is detected again before a block starts. Existing blocks retain their normal break and end controls if setup later needs attention.

The app bundles its service and maintenance tools. For manual development installation:

```sh
sudo '/path/to/HardPause.app/Contents/Resources/install-macos-service.sh'
```

### Updates

Installation authorizes the current non-root user and the signed app and CLI.
Other users or binaries cannot control the service.

**Update protection** preserves saved plans and enrollment. The replacement
clients must match the enrolled signing requirements. A service with handoff
support can update during a later active block while the separate browser
worker and old service keep enforcement on. The installed v2 service cannot do
this; its first migration requires inactive protection.

For an older service or a changed signing requirement, the installer's `--reenroll`
path preserves saved plans only after live and offline checks confirm inactive
protection. See [agent maintenance guidance](#agent-maintenance-guidance) before
removal or recovery.

For a local handoff check, run `scripts/test-macos-service-handoff-local.sh` from the repository root. It builds development-signed fixture apps and uses separate launchd names, root storage, Keychain items, a copy of the hosts file, and PF anchors. It requests one administrator approval after building. A failure leaves its test evidence for inspection. It does not migrate the installed v2 service.

## Enforcement boundary

- Each saved host name becomes an exact protected hosts entry. The **Include subdomains** switch adds browser coverage for all subdomains and an exact `www` hosts entry.
- **Block adult websites** automatically downloads a domain database from The Block List Project on first launch, then checks it locally and refreshes it daily. An internet connection is required for the first download; plans using this filter cannot start until it completes. Updates contain no browsing data; failed or incomplete downloads retain the last valid list. Database matches include subdomains. This category uses browser protection, not system-wide DNS filtering.
- Chrome and Safari can also read RTA rating meta tags from the current page when **Allow JavaScript from Apple Events** is enabled. No separate page fetch occurs. Firefox uses the domain list and saved ratings but cannot read new RTA tags; RTA response headers are not inspected. Positive RTA page matches are cached locally for 24 hours across restarts, as URL hashes and expiry times in a private file. An RTA page label does not classify its entire host. No filter catches every adult site.
- Literal IPv4 and IPv6 rules use an owned PF child anchor. The service does not resolve domains to CDN addresses, reload the main PF ruleset, flush global state, or disable PF.
- Selected apps are closed while a contributing block is active. The service checks their signed designated requirements. Closing an app can lose unsaved work and does not prevent an administrator from changing the system.
- Active plans can gain website, application, and adult-site rules. Existing rules, the plan name, and waiting periods stay fixed. A break removes only that block from the effective union; overlapping blocks continue to apply. A fixed duration can end its block before a pending request completes.
- The service encrypts saved plan state, pending transitions, and Screen Time setup state with AES-256-GCM and a System Keychain key. A Keychain anchor detects direct edits, missing files, and rollback of plan state to an older encrypted file. An administrator with control of the service or Keychain can still defeat software-only protection. Legacy state is encrypted on load only when protection is inactive.
- VPNs, proxies, encrypted DNS, existing connections, and direct addresses can bypass host-name controls. A local administrator can stop or remove the service. Browser redirects also check full tab URLs. Hard Pause does not decrypt page content.

No browser extension, Network Extension, hosted service, account, or analytics
is required.

## Browser page protection

- Add domains, IPs, or URL patterns in the same website field. Whole hosts retain network enforcement. Page paths and `*` patterns stay out of hosts and PF.
- `reddit.com/r/example` matches that path and its descendants. `*.example.com` matches subdomains; add `example.com` for the bare host. `*.xxx` matches names under that TLD. `*` in a path or query matches any sequence.
- Chrome and Safari use their tab automation APIs. Use **Allow access** in Hard Pause to request macOS permission. The browser monitor runs outside the App Sandbox so it can also use user-approved Accessibility controls for Firefox.
- Closing an approved browser keeps setup complete, including after restarting Hard Pause. Access is checked again when the browser runs; saved approval never authorizes tab access.
- A loopback-only server exposes an exact allowlist of bundled pause-page, mascot, and font assets. Redirects contain no original URL, and the app stores no browsing history.
- Normal window closure and Quit leave the app running while a website block is active. System logout is allowed. Starting a page-pattern block in the GUI requires browser permission and login startup.
- Direct CLI activation is an administrative interface: configure browser access and login startup first. The root service does not perform browser automation.

## Development checks

Run `scripts/check-native.sh` from the repository root for native checks, or
`swift test --package-path core` for shared lifecycle and storage tests. These
checks do not install protection. Real service, reboot, browser, and Screen Time
checks remain separate.

The shared artwork is in `web/mascot/`. After changing its static first frame,
run `swift scripts/render-icons.swift` to refresh both app icon sets.

## Agent maintenance guidance

[AGENTS.md](../AGENTS.md) defines the user's commitment during active blocks. The build bundles it; installation copies it beside the privileged tools and protected state. Removal and recovery commands display it before maintenance. `hard-pause agent-guidance` prints it without contacting the service. Service logs and the launchd file also point agents to it. No normal app screen displays this text.

This is guidance for cooperating agents, not access control. It cannot force an agent to read it or prevent an administrator from bypassing the service.
