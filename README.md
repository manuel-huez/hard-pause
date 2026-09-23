# Hard Pause

<p align="center"><img src="web/mascot/first-frame.svg" alt="Hard Pause mascot" width="220"></p>

**Choose what to block. Set the wait. Give yourself time before access returns.**

Hard Pause is a local app for iPhone, iPad, and Mac that blocks selected apps and
websites. Named plans let you keep separate commitments, each with its own rules
and waiting periods. The apps use native SwiftUI controls and a shared animated
mascot.

[Visit the Hard Pause website](https://manuel-huez.github.io/hard-pause/).

**In development.** Requires iOS 26+ or macOS 26+. Physical-device enforcement and
the Mac Screen Time setup flow still need validation. An early
[Mac download](https://github.com/manuel-huez/hard-pause/releases/latest) is development signed
and not notarized.

## Two ways to pause

| Mode           | Breaks                           | How access returns                                            |
| -------------- | -------------------------------- | ------------------------------------------------------------- |
| **Pause**      | Available after the wait you set | A timed break, an optional fixed end, or the full-unlock wait |
| **Hard Pause** | No breaks                        | Only after the full-unlock wait                               |

- **Separate plans, shared protection.** If two plans block the same app or site, both must allow access before it opens.
- **A commitment that stays fixed.** Starting a plan fixes its name and timing. Mac plans can add rules while active; existing rules cannot be removed. iOS keeps active rules fixed.
- **Local by design.** No account, telemetry, hosted API, or browsing-history uploads. Mac adult-site lists download over HTTPS; matching stays on the device.

## Start here

| I want to…                       | Guide                                       |
| -------------------------------- | ------------------------------------------- |
| Download or build the Mac app    | [macOS guide](macos/README.md)              |
| Build for iPhone or iPad         | [iOS guide](ios/README.md)                  |
| Understand the protection limits | [Design and security boundaries](DESIGN.md) |
| Work on the shared lifecycle     | [Shared Apple core](core/README.md)         |

### What each platform protects

**Mac:** a local root service manages plans and waiting periods, blocks exact
host names and literal IP addresses, and closes selected signed apps. Browser
controls cover page patterns, subdomains, and adult-site filtering. Closing apps
can lose unsaved work. Administrators, VPNs, proxies, and encrypted DNS can bypass
parts of this protection. The experimental Screen Time code flow is not yet
verified on a real device.

**iPhone and iPad:** Apple's Screen Time APIs shield selected apps and websites.
Up to 16 plans can be active. App-removal and automatic-date protection are
available, but permission changes, reboot behavior, and background transitions
still need signed-device tests. Mac setup does not prove iPhone protection.

## Development

Use Node.js 22.13+, Xcode, and XcodeGen. CI uses Xcode 26.6. Native signing and
capability requirements are in the platform guides.

```sh
npm ci
npm run check
swift test --package-path core
```

For browser checks, run `npx playwright install chromium` then
`npm run test:browser`. Run `scripts/check-native.sh` for the full native checks.
These checks do not install the Mac service or enable real blocks.

| Folder          | Contents                                             |
| --------------- | ---------------------------------------------------- |
| [ios](ios/)     | iPhone and iPad app, Screen Time extensions          |
| [macos](macos/) | Mac app, root service, command-line client           |
| [core](core/)   | Shared lifecycle, elapsed clock, and storage helpers |
| [web](web/)     | Product website and shared mascot renderer           |

The source has no general license grant. The bundled mascot has its own license
and attribution notices in `web/mascot/`.
For maintenance that affects a commitment, read [AGENTS.md](AGENTS.md).
