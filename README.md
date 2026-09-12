# Hard Pause

Hard Pause is a local iPhone, iPad, and Mac app for intentional breaks from selected apps and websites. It targets iOS 26 and macOS 26 with native SwiftUI and Liquid Glass. The project is in development and is not ready for trusted enforcement.

| Folder          | Purpose                                                     |
| --------------- | ----------------------------------------------------------- |
| [web](web/)     | Static Low Light product website and shared mascot renderer |
| [ios](ios/)     | SwiftUI app and native Screen Time extensions               |
| [macos](macos/) | SwiftUI app, local root service, and command-line client    |

## Product rules

- Create independent named blocks with app and website rules, separate break and full-unlock delays, a break length, and an optional fixed duration.
- Activation fixes the block name, rules, and timing. An active block cannot be edited or deleted, including during a break.
- A request affects only its block. Overlapping rules remain until every block that contains them allows access.
- A fixed duration ends only its block and takes priority over a pending request or break.
- Protection and storage failures must remain visible.
- No account, telemetry, hosted API, browsing history, remote classification, browser extension, or paid enforcement tier.

## Platform design

| Platform  | Local enforcement                                                                                                                                                                                                                                        | Limits before release                                                                                                                                                                 |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| iOS 26+   | Family Controls selection, Managed Settings shields, and Device Activity transitions; at most 16 active named blocks                                                                                                                                     | Apple approval, permission revocation, app removal, reboot, and background delivery need signed-device tests                                                                          |
| macOS 26+ | Root launchd service with authoritative rules and elapsed deadlines; exact domains in the hosts file; literal IP rules through an active PF `com.apple/*` dispatcher; selected signed apps are closed; browser URL rules redirect to a local mascot page | Administrators can remove the service; exact domains do not imply wildcard subdomains; VPNs and encrypted DNS can bypass hosts/PF coverage; closing an app can interrupt unsaved work |
| Website   | Product information and source/build links                                                                                                                                                                                                               | The website does not block, store settings, or simulate enforcement                                                                                                                   |

The macOS design uses no browser, Network Extension, or Endpoint Security extension. It preserves unrelated hosts and PF rules, does not change system DNS, and does not expand domains to changing CDN addresses. The installed command-line client uses the same service and unlock rules as the app.

The website and both native apps share the local renderer in `web/mascot/`. Native controls remain SwiftUI; only the character uses bundled web content. Preserve the renderer's `LICENSE.txt` and `NOTICE.txt` files.

See [DESIGN.md](DESIGN.md) for the security boundaries and release checks. Each platform README has build instructions and current implementation details.

## Development

Use Xcode 26.6 and XcodeGen. Website files need only a local static server. Do not enable real blocks on a primary device until the device test checklist passes.

| Command or workflow                                       | Purpose                                                              |
| --------------------------------------------------------- | -------------------------------------------------------------------- |
| `npm ci && npm run check`                                 | Pinned formatting, lint, and JavaScript tests                        |
| `npx playwright install chromium && npm run test:browser` | Landing-page, local-asset, CSP, responsive-layout, and mascot checks |
| `npm run format`                                          | Format web, configuration, and Markdown files                        |
| `xcrun swift-format format -i -r ios macos`               | Format Swift with the checked-in rules                               |
| `scripts/check-native.sh`                                 | Project generation, capability checks, and native tests              |
| GitHub Actions → Checks                                   | Website artifact and native test results                             |

CI uses Xcode 26.6 on `macos-26`, read-only repository permissions, and pinned action revisions. It runs on each push and pull request. Dependabot checks development tools and actions weekly.

Website deployment is opt-in through the **Deploy website to GitHub Pages** workflow. No deployment is part of the local build or test commands.

There is no public installer, checkout, or licensing server. An Apple team, approved capabilities, provisioning, installed-service tests, and signed-device verification are still required. A source license must be selected before release; no license grant is implied yet.
