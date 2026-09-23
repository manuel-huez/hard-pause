# macOS release

## Temporary development-signed release

Use this path for `v0.1.1` (app version `0.1.1`, build `3`) while Developer ID and notarization credentials are unavailable. It uses the Apple Development identity on this Mac and the `hard-pause` Sparkle key in the local Keychain. The script reads no private key file and does not change the installed app or service.

1. Commit the version, generated project, updater, and release files. Wait for repository Checks to pass for that commit.
2. Run `scripts/release-macos-development.sh prepare v0.1.1`. Approve local Keychain access when macOS asks. Inspect `build/release-development/v0.1.1/HardPause-macOS.zip` and `appcast.xml`.
3. Push a `v0.1.1` tag for that same commit. Run `scripts/release-macos-development.sh stage v0.1.1`; it verifies the remote tag and creates a **draft** GitHub Release with both assets.
4. Inspect the draft assets and release notes, then publish the draft. Publish it as a normal release, not a GitHub prerelease: the app uses `/releases/latest/download/appcast.xml`, which selects the latest published normal release.

This build is not notarized. Other Macs can need manual approval for the first launch. Automatic background updates are disabled; update acceptance and service update behavior still need an inactive test installation on another Mac. A later move from Apple Development to Developer ID changes the signing identity; test that update path before promising it. Do not use the installed service on this Mac as a release test while a block is active.

## Developer ID release

Run [Release macOS](../.github/workflows/release-macos.yml) manually with an existing `vMAJOR.MINOR.PATCH` tag whose version matches `macos/project.yml`. The job builds with Developer ID, notarizes and staples the app, signs the final ZIP with Sparkle EdDSA, and publishes `HardPause-macOS.zip` and `appcast.xml` in one GitHub Release. The feed URL is `https://github.com/manuel-huez/hard-pause/releases/latest/download/appcast.xml`. Increment `CURRENT_PROJECT_VERSION` for each new release.

Create the `macos-release` GitHub environment with required reviewers. Protect `v*` tags with a repository ruleset. Set these environment secrets before tagging:

| Secret                            | Value                                                                                                               |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `APPLE_DEVELOPER_ID_P12_BASE64`   | Base64 of the Developer ID Application `.p12` for team `ZBX6C7BJ5X`                                                 |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password for that `.p12`                                                                                            |
| `APPLE_DEVELOPER_ID_IDENTITY`     | Exact `Developer ID Application: … (ZBX6C7BJ5X)` identity                                                           |
| `APPLE_NOTARY_API_KEY`            | Contents of the App Store Connect notary API `.p8` key                                                              |
| `APPLE_NOTARY_KEY_ID`             | ID of that API key                                                                                                  |
| `APPLE_NOTARY_ISSUER_ID`          | App Store Connect issuer ID                                                                                         |
| `SPARKLE_EDDSA_PRIVATE_KEY`       | Contents of a private key file exported with Sparkle `generate_keys --account hard-pause -x`; keep the file private |
| `SPARKLE_EDDSA_PUBLIC_KEY`        | Matching public key from Sparkle `generate_keys`; this value is embedded in the app                                 |

The dedicated Sparkle key was generated with `generate_keys --account hard-pause` from the pinned Sparkle package. Its private key is in the local Keychain; its public key is `hqO11mB5r81uup2mbAJ1oYRwbVbEFxczONdXHFZVD8U=`. Back up the private key securely before using it for releases, and provision the CI secret through the GitHub environment without adding it to Git, command output, or workflow logs. The CI job writes it to a restricted temporary file for `sign_update -f` and removes that file after signing. A missing or invalid credential stops the release. A failed run may leave a draft release that must be reviewed before retrying.

The job checks the app and bundled service and CLI signatures, key and version metadata, notarization ticket, Gatekeeper assessment, and Sparkle signature output. A successful release still needs a clean-machine install and update check before it can be treated as a field-tested distribution. Never test an update by changing an active Hard Pause block or its protected state.
