# Hard Pause for macOS

The macOS app is a SwiftUI client for an authenticated root launchd service. The service owns saved blocks, elapsed-time transitions, and system enforcement. The GUI reads that protected state for browser redirects; it has no separate policy store.

## Requirements and build

- macOS 26.0 or later.
- The latest stable macOS SDK selected with `SDKROOT=macosx`.
- XcodeGen.
- An Apple Development signing identity in the login keychain for local app builds.

Build the installed app with certificate signing:

```sh
xcodegen generate --spec macos/project.yml
xcodebuild -project macos/HardPause.xcodeproj -scheme HardPause -configuration Release -destination 'platform=macOS' -derivedDataPath build/macos build
```

The project uses `Apple Development` signing. If multiple identities are available, pass `CODE_SIGN_IDENTITY='<certificate name or SHA-1>'`. Keep the same signing identity, bundle ID, and app location across updates. Do not override signing with `CODE_SIGN_IDENTITY=-`: ad-hoc builds can reset macOS permissions. The installer preserves the built signatures. Switching from ad-hoc signing requires one new permission approval; certificate signing does not grant permissions by itself. Unsigned CI tests can still use `CODE_SIGNING_ALLOWED=NO`.

Generate the project with `xcodegen generate --spec macos/project.yml`. The `HardPause` scheme builds and tests these products:

| Target                  | Product              | Purpose                                            |
| ----------------------- | -------------------- | -------------------------------------------------- |
| `HardPause`             | `HardPause.app`      | SwiftUI GUI, browser redirects, and XPC client     |
| `HardPauseService`      | `hard-pause-service` | Root launchd service                               |
| `HardPauseCLI`          | `hard-pause`         | Local administration tool                          |
| `HardPauseTests`        | Test bundle          | Block and IPC contract tests                       |
| `HardPauseServiceTests` | Test bundle          | Persistence, authentication, and enforcement tests |

An ad hoc signed local build can install and run the service without a paid Apple Developer account. A public download needs Developer ID signing and Apple notarization. An unsigned build can test code and show the real setup state, but the installer rejects an unsigned app.

## Local installation

On first launch, complete the setup in the app:

1. Select **Install protection** and approve the standard macOS administrator prompt. The app never handles the password.
2. Select **Allow access** for each installed browser. Keep the browser open and approve the macOS permission request. If access was denied, Hard Pause opens the permission pane. The app detects the approval.
3. Enable **Start at login**.

The normal setup does not require finding app files or using Terminal. Readiness is detected again before a block starts. Existing blocks retain their normal break and end controls if setup later needs attention.

The built app includes the installer, uninstaller, validation script, service executable, command-line tool, and launchd property list. For manual development installation:

```sh
sudo '/path/to/HardPause.app/Contents/Resources/install-macos-service.sh'
```

Installation enrolls the current non-root user and the signed requirements of the GUI and command-line tool. The service rejects another user or binary. **Update protection** uses `--update` to retain enrollment and saved plans; all plans must be inactive and protection must report no issues. The installed service must support the update gate, which prevents plan changes until the update finishes and survives service restarts. Older services fail closed. Replacement clients must satisfy the existing signing requirements. For an older service or a changed signing requirement, `--reenroll` preserves saved plans only after live and offline checks confirm inactive protection.

Do not test installation on a primary Mac until the installer, removal, reboot, and recovery checks pass. The development checks do not install launchd files, change hosts or PF rules, or close real apps.

## Enforcement boundary

- Each saved host name becomes an exact protected hosts entry. The **Include subdomains** switch adds browser coverage for all subdomains and an exact `www` hosts entry.
- **Block adult websites** automatically downloads a domain database from The Block List Project on first launch, then checks it locally and refreshes it daily. An internet connection is required for the first download; plans using this filter cannot start until it completes. Updates contain no browsing data; failed or incomplete downloads retain the last valid list. Database matches include subdomains. This category uses browser protection, not system-wide DNS filtering.
- Chrome and Safari can also read RTA rating meta tags from the current page when **Allow JavaScript from Apple Events** is enabled. No separate page fetch occurs. Firefox uses the domain list and saved ratings but cannot read new RTA tags; RTA response headers are not inspected. Positive RTA page matches are cached locally for 24 hours across restarts, as URL hashes and expiry times in a private file. An RTA page label does not classify its entire host. No filter catches every adult site.
- iOS retains Apple's automatic web-content filter; this macOS database does not replace it.
- Literal IPv4 and IPv6 rules use an owned PF child anchor. The service does not resolve domains to CDN addresses, reload the main PF ruleset, flush global state, or disable PF.
- Selected apps are closed while a contributing block is active. The service checks their signed designated requirements. Closing an app can lose unsaved work and does not prevent an administrator from changing the system.
- Active plans can gain website, application, and adult-site rules. Existing rules, the plan name, and waiting periods stay fixed. A break removes only that block from the effective union; overlapping blocks continue to apply. A fixed duration can end its block before a pending request completes.
- The service encrypts saved plan state, pending transitions, and Screen Time setup state with AES-256-GCM and a System Keychain key. A Keychain anchor detects direct edits, missing files, and rollback of plan state to an older encrypted file. An administrator with control of the service or Keychain can still defeat software-only protection. Legacy state is encrypted on load only when protection is inactive.
- VPNs, proxies, encrypted DNS, existing connections, and direct addresses can bypass host-name controls. A local administrator can stop or remove the service. Browser redirects also check full tab URLs. Hard Pause does not decrypt page content.

The old Network Extension target and shared writable GUI policy file were removed. The production route does not need browser extensions, a hosted service, accounts, analytics, or remote classification.

## Browser page protection

- Add domains, IPs, or URL patterns in the same website field. Whole hosts retain network enforcement. Page paths and `*` patterns stay out of hosts and PF.
- `reddit.com/r/example` matches that path and its descendants. `*.example.com` matches subdomains; add `example.com` for the bare host. `*.xxx` matches names under that TLD. `*` in a path or query matches any sequence.
- Chrome and Safari use their tab automation APIs. Use **Allow access** in Hard Pause to request macOS permission. The browser monitor runs outside the App Sandbox so it can also use user-approved Accessibility controls for Firefox.
- Closing an approved browser keeps setup complete, including after restarting Hard Pause. Access is checked again when the browser runs; saved approval never authorizes tab access.
- A loopback-only server exposes an exact allowlist of bundled pause-page, mascot, and font assets. Redirects contain no original URL, and the app stores no browsing history.
- Normal window closure and Quit leave the app running while a website block is active. System logout is allowed. Starting a page-pattern block in the GUI requires browser permission and login startup.
- Direct CLI activation is an administrative interface: configure browser access and login startup first. The root service does not perform browser automation.

The shared cloud artwork is in `web/mascot/`. After changing its static first frame, run `swift scripts/render-icons.swift` from the repository root to refresh both app icon sets.

## Agent maintenance guidance

[AGENTS.md](../AGENTS.md) defines the user's commitment during active blocks. The build bundles it; installation copies it beside the privileged tools and protected state. Removal and recovery commands display it before maintenance. `hard-pause agent-guidance` prints it without contacting the service. Service logs and the launchd file also point agents to it. No normal app screen displays this text.

This is guidance for cooperating agents, not access control. It cannot force an agent to read it or prevent an administrator from bypassing the service.
