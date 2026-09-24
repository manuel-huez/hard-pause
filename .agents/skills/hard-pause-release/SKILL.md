---
name: hard-pause-release
description: Prepare, publish, and verify signed Hard Pause macOS GitHub Releases and Sparkle updates. Use for releases, not routine builds or website deployment.
---

# Hard Pause macOS release

Read [AGENTS.md](../../../AGENTS.md) before installed-app or service work. A release can be published while a block is active; do not change the installed service or interrupt enforcement. Use an inactive test installation for update checks. Treat source tests, a published release, and the running app and service as separate results.

## Choose the signing path

- **Development signed:** The user accepted Apple Development signing while Developer ID and notarization credentials are unavailable. Use `scripts/release-macos-development.sh`. The first launch on another Mac may need manual approval; state that the download is not notarized.
- **Developer ID:** Use [.github/workflows/release-macos.yml](../../../.github/workflows/release-macos.yml) only after the `macos-release` environment has a Developer ID Application certificate, App Store Connect notarization API key, and Sparkle EdDSA key. The workflow requires notarization, stapling, Gatekeeper acceptance, and signature checks. Never print or commit credentials.

The Sparkle public key is `hqO11mB5r81uup2mbAJ1oYRwbVbEFxczONdXHFZVD8U=`. Its private key is in the local Keychain under account `hard-pause`; the development script reads it through Sparkle's pinned signing tool. The Developer ID workflow expects the `APPLE_DEVELOPER_ID_P12_BASE64`, `APPLE_DEVELOPER_ID_P12_PASSWORD`, `APPLE_DEVELOPER_ID_IDENTITY`, `APPLE_NOTARY_API_KEY`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, `SPARKLE_EDDSA_PRIVATE_KEY`, and `SPARKLE_EDDSA_PUBLIC_KEY` environment secrets. Protect `v*` tags and require reviewers for the release environment.

## Prepare and publish

1. Match the `vMAJOR.MINOR.PATCH` tag to `MARKETING_VERSION` in `macos/project.yml`; increase `CURRENT_PROJECT_VERSION` for each Mac release. Increase `ProtectedServiceContract.serviceVersion` when its wire protocol changes. The service update checks the higher app build and changes to the signed service binary. Commit the source and generated project. Require repository Checks and `scripts/test-macos-service-handoff-local.sh` to pass for that exact commit before tagging. The local fixture uses separate system names and leaves the installed service untouched.
2. For the development path, run `scripts/release-macos-development.sh prepare <tag>`. Approve Keychain access if macOS asks. Inspect the ZIP and appcast under `build/release-development/<tag>/`.
3. Push the tag for the checked commit. Run `scripts/release-macos-development.sh stage <tag>` to create a draft with both assets. Inspect that draft and publish it as a normal release. The app feed uses `/releases/latest/download/appcast.xml`, which excludes drafts and prereleases.
4. For Developer ID, run the release workflow on that tag. Inspect any existing draft before retrying a failed run; never overwrite a published release blindly.

## Verify

Check the published ZIP's byte length, version, build, code signature, and Sparkle EdDSA signature against the appcast. Fetch `https://github.com/manuel-huez/hard-pause/releases/latest/download/appcast.xml` and confirm it serves the intended release. For Developer ID, confirm the stapled ticket and Gatekeeper acceptance. Check app, service, CLI, and browser worker signatures.

Use the local fixture to check active handoff and rollback. Read the running app and service versions separately. If only source tests ran, report native handoff and installed behavior as unverified. An installed v2 service cannot hand off an active block; wait for the normal full unlock before its first migration.
