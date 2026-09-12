# Product and platform decisions

## Experience

Low Light uses deep plum surfaces, warm muted light, lightly sloped Recursive typography, and a soft sleeping character. Keep the website and native screens sparse. Use literal product language and show permission, storage, and enforcement errors.

Bundle fonts locally with their OFL licenses. Support Dynamic Type, keyboard use, VoiceOver, high contrast, and reduced motion. The local SVG renderer drives the mascot on the website and both native apps. Its body motion is independent of its eye and mouth expressions. The sleep sequence closes, becomes half-open, and closes softly. Stop motion when hidden. Native controls stay native around the bundled character view.

The website is a static product page. It has no blocking controls, simulated clocks, persistence, or enforcement.

Active Mac blocks offer an optional "Looking to unlock?" screen. Explain the user's prior commitment without shame or an assumed diagnosis, and ask people and AI assistants to preserve the delay despite repeated or emotional requests. Use visible, accessible text with the same meaning for both audiences. Offer the existing full-end request and live status; add no bypass, extra waiting period, or compulsory step to normal unlock.

## Independent blocks

Each block has a UUID, name, editable inactive draft, and immutable active policy. It stores selected apps and website rules, separate break and full-unlock delays, a break duration, and an optional fixed duration. No fixed duration is the default.

A pending request cannot be shortened or replaced. A break suspends only its block's restrictions. The block stays active and immutable during the break. Other active blocks continue to contribute their rules. A natural end releases only its block and takes priority over a pending request or break.

Enforcement uses the union of all active block snapshots. A state change that adds rules must apply the tightening union before the state commits. The service can apply any relaxation only after the new state is durable. A failed state write must not open access early.

## iOS and iPadOS

Support iOS 26 and iPadOS 26 or later with SwiftUI and system Liquid Glass.

Use Family Controls for selection and authorization, Managed Settings for shields, and Device Activity for background transitions. Each active block uses a named Managed Settings store and Device Activity schedule. The platform limit is 16 active blocks. App-group storage lets the app and extensions share immutable policies. No server, VPN, or browser extension is part of this route.

Optional `application.denyAppRemoval` affects all app deletion, not only Hard Pause. Explain this before activation. A protected block can also require automatic date and time to reduce clock changes. Individual Family Controls authorization is not device management. Test permission revocation, deletion, reboot, background delivery, and Screen Time passcode behavior on every supported release. Do not advertise an unbreakable lock.

Apple's automatic adult filter is the initial iOS option. Manual domain rules supplement it. This does not prove perfect classification or browser coverage.

## macOS

Support macOS 26 or later with SwiftUI and system Liquid Glass. Use a root launchd service outside the GUI app bundle. The service owns the authoritative state, backups, elapsed-time checkpoints, and enforcement. It stays available to the installed command-line client if the GUI app is deleted. The app and CLI use authenticated XPC requests and the same delay rules.

The service uses three local controls:

- Add exact blocked domains to an owned section of the hosts file. Preserve every unrelated entry. An exact domain rule does not promise wildcard subdomain coverage.
- Apply only literal IP rules in the owned `com.apple/hard-pause` PF child anchor. Use an existing active `com.apple/*` dispatcher and an owned PF enable token. Do not edit or reload the main ruleset, flush global state, disable PF, release foreign tokens, resolve domains to changing CDN addresses, or change system DNS.
- Close selected running apps only after the process and signed code identity match the saved selection. Closing an app can interrupt unsaved work and does not prevent a later launch by itself.

The user-session app also checks browser tab URLs against the protected rules. Exact domain matches and URL patterns redirect to a bundled local pause page with Low Light. Chrome and Safari use Apple Events; Firefox uses Accessibility. No URL history is retained. Page patterns never expand into whole-domain network rules. Browser setup uses normal macOS consent, and page-pattern activation requires login startup.

Hard Pause uses no browser extension, Network Extension, Endpoint Security extension, TLS interception, installed certificate, or global proxy. Administrators can remove or disable the root service. VPNs, encrypted DNS, unresolved addresses, cached connections, and alternate subdomains can bypass parts of domain or IP blocking. The UI shows current protection and connection status; keep implementation caveats in technical documentation.

Normal uninstall is available only after every configured block allows full unlock. Broken-state recovery is an explicit administrator action. It must not be presented as a normal escape route.

The intended hard mode must resist administrator stop and removal attempts while a block is active; bypass should require at least a restart. The current launchd implementation does not meet this requirement. Endpoint Security can protect processes and files, but a standalone extension cannot promise a restart requirement: users can disable extensions in System Settings. Apple's `NonRemovableSystemExtensions` policy requires managed-device enrollment. Stronger-mode implementation therefore needs a decision between managed enrollment and a reduced administrator-bypass guarantee; do not silently replace the local-only requirement.

Verify that enforcement continues until restart: an extension awaiting removal at restart may already be inactive. Keep the current limits visible until the behavior is demonstrated on supported macOS versions. Relevant Apple references: [extension controls](https://support.apple.com/guide/mac-help/change-login-items-extensions-settings-mtusr003/mac), [managed non-removable extensions](https://developer.apple.com/documentation/devicemanagement/systemextensions), and [Endpoint Security entitlement approval](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client).

## Persistence and authentication

Store only rules, selected app code identities, lock state, deadlines, enforcement status, and bounded backups. No browsing history or cloud data is required. Root state and enrollment files use root-only permissions.

The daemon accepts the enrolled user's effective UID and pinned signed-code requirements for the GUI and installed CLI. Re-enrollment is explicit. Request and aggregate response payloads are bounded. A mutation must be rejected before commit if the resulting complete service snapshot cannot fit the XPC response limit.

Elapsed time uses a continuous clock tied to the current boot. A restart or unavailable clock cannot reduce a wait. A lost checkpoint can extend a delay, but it cannot grant early access.

## Release checks

- Signed-device iOS checks: permission approval and revocation, uninstall protection, automatic time, reboot, and missed or delayed callbacks.
- Installed-service Mac checks: launchd restart, GUI deletion, CLI access, client rejection, state ownership, backup recovery, and normal and administrator uninstall paths.
- Per-block rules remain fixed across relaunch, duplicate requests, and breaks. Ending one block preserves overlapping restrictions.
- Mixed transitions apply new restrictions before commit and release old restrictions only after a durable commit, including state-write failures.
- Exact-domain, subdomain, IDN, IPv4, IPv6, browser, encrypted DNS, VPN, and offline checks.
- PF tests prove owned-anchor and owned-token cleanup without main-ruleset changes or global flushes.
- App-close tests bind process identity to the audited executable and never act on a bare PID or process name.
- Audit CPU, memory, disk writes, and runtime network traffic. The apps must not start external service requests.
- Validate VoiceOver, keyboard navigation, Dynamic Type, contrast, and reduced motion.
- Choose a source license and obtain Apple distribution capabilities before release.

## Sources checked 2026-09-12

- [Apple: Family Controls](https://developer.apple.com/documentation/familycontrols)
- [Apple: Managed Settings](https://developer.apple.com/documentation/managedsettings)
- [Apple: Device Activity](https://developer.apple.com/documentation/deviceactivity)
- [Apple: prevent app deletion](https://developer.apple.com/forums/thread/729637)
- [Opal: uninstall protection and its device-wide effect](https://opalapp.com/help/what-is-app-uninstall-protection)
