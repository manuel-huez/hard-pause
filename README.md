# Hard Pause

<p align="center"><img src="web/mascot/first-frame.svg" alt="Hard Pause mascot" width="220"></p>

**Choose what to block. Set the wait. Give yourself time before access returns.**

[Hard Pause](https://manuel-huez.github.io/hard-pause/) is a local app for iPhone, iPad, and Mac that blocks selected apps and
websites. Named plans let you keep separate commitments, each with its own rules
and waiting periods.

**In development.** Requires iOS 26+ or macOS 26+.

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

## Development

```sh
npm ci
npm run check
cargo test --manifest-path core/rust/Cargo.toml --locked
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
