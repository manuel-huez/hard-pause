---
name: hard-pause-release
description: Prepare, publish, and verify signed Hard Pause macOS GitHub Releases and Sparkle updates. Use for release work, not routine local builds or website deployment.
---

# Hard Pause release

Read the [release guide](../../../docs/macos-release.md) and
[release workflow](../../../.github/workflows/release-macos.yml) for current
credentials, artifact names, and commands. Read [AGENTS.md](../../../AGENTS.md)
before any installed-app or service work. Keep procedures in those files rather
than duplicating them here.

## Preserve active protection

Never stop or unload the installed service, rewrite protected state, shorten waits,
or interrupt browser enforcement during an active block, break, or pending unlock.
A missing GUI or unreadable service state does not prove that blocks are inactive.
Installed service v2 has no live handoff; do not claim active service updates are
supported. Publishing a release does not require installing it on this Mac.

Use an inactive test installation for install and update checks. If the current Mac
has active blocks, use read-only version and health checks and report local update
validation as pending. Do not bypass an update gate to finish a release.

## Prepare and publish

- Confirm the requested version and target commit. Publish when the user has
  authorized a release, including authorization given earlier in the task.
- Match the version tag to the app version and increase the build number. Require
  successful repository Checks for that exact commit before pushing the release tag.
- For a development release explicitly accepted by the user, use
  `scripts/release-macos-development.sh` and the local Apple Development identity.
  Verify its Sparkle signature and state clearly that it is not notarized.
- For a Developer ID release, confirm the protected environment and credentials
  without printing secrets. Use the workflow and require Developer ID signatures,
  accepted notarization, a stapled ticket, Gatekeeper acceptance, and a Sparkle
  signature. Missing credentials block this release path.
- Stage both the ZIP and appcast in a draft, inspect them, and publish them in
  one normal GitHub Release. If a run fails, inspect its draft and assets before
  retrying; do not overwrite a published release blindly.

## Verify and report

Check the release workflow result and download the published assets. Confirm that
the appcast's URL, byte length, signature, version, and build match the archive;
verify the downloaded app's signature and, for Developer ID releases, its
notarization ticket. Fetch the configured
latest feed and confirm it serves the intended release, not a draft or prerelease.

On an inactive test installation, check install, launch, and update behavior. Read
the running app and service versions separately; an app update does not prove a
service update. Report the release URL, commit, versions, CI results, feed result,
and any untested runtime checks. Distinguish published, installed, and running
versions. Never describe source-only checks as live enforcement validation.
