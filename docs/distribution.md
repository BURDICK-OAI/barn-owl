# Distribution

BarnOwl has two shareable artifact types:

- Source handoff for another developer to build and inspect.
- App package for someone who only needs to run BarnOwl.

Do not send the raw working folder. It can contain local build products, `.env.local`,
Git objects, Xcode state, and other machine-specific files. Generate artifacts under
`dist/` instead.

## Build Artifacts

```sh
scripts/package-all.sh
```

This creates:

- `dist/BarnOwl-source-handoff.zip`
- `dist/BarnOwl.app.zip`
- `dist/BarnOwl-release-manifest.json`
- `dist/BarnOwl-update-manifest.json`
- `dist/SHA256SUMS`

Send those files only. `dist/` is ignored by Git and can be regenerated any time
from the current source.

## Internal/GitHub Download Checklist

Barn Owl is distributed through GitHub Releases as a direct-download macOS app
package, not through the Mac App Store. GitHub Releases are the canonical
download and update path. Attach:

- `BarnOwl.app.zip`
- `BarnOwl-source-handoff.zip`
- `BarnOwl-release-manifest.json`
- `BarnOwl-update-manifest.json`
- `SHA256SUMS`

Before sharing, verify checksums locally:

```sh
cd dist
shasum -a 256 -c SHA256SUMS
```

Or run the full dist integrity check:

```sh
scripts/verify-dist.sh dist
```

That command verifies the expected file set, `SHA256SUMS`, release manifest
artifact paths, manifest SHA-256 values, the update manifest, and the app package
release gate.

The lightweight internal path uses an ad-hoc signed app plus checksum-verified
manifests. Recipients may see Gatekeeper friction on first launch because the app
is not notarized. That is an intentional tradeoff for a small internal tool.

For a package that opens cleanly on another Mac without Gatekeeper warnings, use
the optional Developer ID flow below and confirm `scripts/verify-release.sh
--direct-download dist/BarnOwl.app.zip` passes.

The optional Developer ID release-candidate command is:

```sh
BARNOWL_CODESIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
BARNOWL_NOTARY_PROFILE="BarnOwlNotary" \
scripts/release-direct-download.sh
```

That command runs the verifier, packages the source and app artifacts, notarizes
and staples the app, runs the strict direct-download gate, and validates
`SHA256SUMS`. It also requires a committed, clean Git checkout so
`BarnOwl-release-manifest.json` can identify the exact source revision. For an
intentional local-only exception, set `BARNOWL_ALLOW_DIRTY_RELEASE=1`; do not use
that override for a shared GitHub/internal release.

## Regenerate Packages

Run this any time you want the shareable zips to include the latest BarnOwl
changes:

```sh
cd /path/to/BarnOwl
scripts/package-all.sh
```

The command replaces the existing zips in `dist/`:

```text
dist/BarnOwl-source-handoff.zip
dist/BarnOwl.app.zip
dist/BarnOwl-release-manifest.json
dist/BarnOwl-update-manifest.json
dist/SHA256SUMS
```

Before sending them, confirm `dist/` contains only the shareable artifacts:

```sh
find dist -maxdepth 1 -type f -print
```

Expected output:

```text
dist/BarnOwl-source-handoff.zip
dist/BarnOwl.app.zip
dist/BarnOwl-release-manifest.json
dist/BarnOwl-update-manifest.json
dist/SHA256SUMS
```

Do not send `.build/`, `DerivedData/`, `.env.local`, the raw repository folder,
or anything outside `dist/`. Those are local development files and can contain
machine-specific state.

Verify a downloaded artifact against `SHA256SUMS` with:

```sh
cd dist
shasum -a 256 -c SHA256SUMS
```

## Clean Local Install

For a local install/update pass that behaves like a new user onboarding, package
the app and install the verified `dist/BarnOwl.app.zip`:

```sh
scripts/package-all.sh
scripts/install-local-app.sh --yes --reset-state
```

The install script verifies the app archive with `scripts/verify-release.sh`,
extracts `BarnOwl.app`, confirms the bundle id is `com.barnowl.mac`, backs up an
existing destination app outside `/Applications`, installs to
`/Applications/Barn Owl.app`, verifies the installed signature, and clears Barn
Owl local data/keychain/TCC decisions when `--reset-state` is passed. Use
`--launch` if you want it to open the app after installation.

`BarnOwl-release-manifest.json` records the app version, build number, packaging
time, source commit when available, signing mode, and the SHA-256 values for the
source and app zips. Use it as the audit record for an internal GitHub release.
Before packaging a new release, add its version/build and highlights to
`Apps/BarnOwlMac/BarnOwlChangelog.json`. The app exposes these release notes from
Settings, `scripts/package-all.sh` fails when the current build has no latest
changelog entry, and the generated update manifest reuses those notes.

If packaging fails, check the build log:

```sh
less .build/package/package-app.xcodebuild.log
```

If the source handoff fails with a secret-scan error, remove the reported secret
from source before regenerating. Do not bypass the scan.

## Source Handoff

```sh
scripts/package-source-handoff.sh
```

The source package script runs `scripts/verify-source-handoff.sh` before
returning. You can also verify an existing archive directly:

```sh
scripts/verify-source-handoff.sh dist/BarnOwl-source-handoff.zip
```

The source package excludes:

- `.git/`
- `.env`, `.env.*` except `.env.example`
- `DerivedData*/`
- `.tools/`
- `.build/`, `build/`, `dist/`
- generated release artifacts such as `BarnOwl.app.zip`,
  `BarnOwl-source-handoff.zip`, `BarnOwl-release-manifest.json`, and
  `SHA256SUMS`
- Xcode user state

The script also runs `scripts/scan-secrets.sh` against the staged source before
creating the archive. The scan checks for common OpenAI keys, non-empty key
environment assignments, private keys, GitHub tokens, and Slack tokens while
excluding generated build output and `.env.example`.

Source handoff packaging also refuses untracked files that would otherwise be
copied into the archive. Stage release files intentionally or keep unrelated
side work out of the release workspace before packaging.

Because `.tools/` is excluded, source handoff recipients need XcodeGen available
on `PATH` to regenerate the project. `scripts/verify.sh` uses the bundled local
copy when present, otherwise falls back to `xcodegen` from `PATH`. If XcodeGen is
not available but `BarnOwl.xcodeproj` is present, it continues with the included
generated project and prints a warning.

## App Package

```sh
scripts/package-app.sh
```

The app package builds `BarnOwl.app`, stages it under `.build/package/`, bundles
the local CLI, Codex skill resources, and Codex MCP app resources, strips debug
symbols, re-signs the staged app ad hoc with hardened runtime enabled, and zips
it into `dist/`.

The app package does not include local recordings, meeting databases, generated
notes, or OpenAI API keys. Recipients need to add their own OpenAI API key in
BarnOwl Settings.

Normal app installs and in-app updates replace only the app bundle. They preserve
the user's Barn Owl recordings, notes, meeting database, preferences, and
Keychain API key. Use `scripts/reset-local-state.sh --yes` or
`scripts/install-local-app.sh --reset-state` only for fresh-onboarding QA.

Remote update archives must be delivered over HTTPS and include a SHA-256
checksum in the update manifest. The archive must contain a valid Barn Owl app
bundle with a valid code signature; ad-hoc signatures are allowed for this
lightweight internal distribution path.

`BarnOwl-update-manifest.json` is the app-facing update feed. You can publish it
beside `BarnOwl.app.zip` in a Git-hosted raw/static location, or send both files
ad hoc. In Settings, point Barn Owl at the manifest URL or local manifest path.
The app checks on launch, periodically while idle, and when the user clicks
Update.

For the default GitHub-backed feed, run:

```sh
scripts/publish-git-update.sh
git add Updates/BarnOwl
git commit
git push origin main
gh release create v0.1.0-build.BUILD dist/BarnOwl.app.zip dist/BarnOwl-source-handoff.zip dist/BarnOwl-release-manifest.json dist/BarnOwl-update-manifest.json dist/SHA256SUMS
```

Installed apps default to:

```text
https://raw.githubusercontent.com/BURDICK-OAI/barn-owl/main/Updates/BarnOwl/BarnOwl-update-manifest.json
```

The tracked manifest points at `BarnOwl.app.zip` attached to the matching
GitHub Release tag; binary zips are not committed to Git history.

For the step-by-step release owner and teammate install flow, see
[`docs/github-release.md`](github-release.md).

### Developer ID Package

Barn Owl is not targeting the Mac App Store. For an internal or GitHub-style
direct download that opens cleanly under Gatekeeper, package with a Developer ID
Application identity and a notarytool keychain profile:

```sh
xcrun notarytool store-credentials "BarnOwlNotary" \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id "APPLE_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

Barn Owl can also create that `notarytool` profile from Apple notarization API
key inputs, which matches common internal CI secret layouts:

```sh
export APPLE_NOTARIZATION_KEY_P8="/path/to/AuthKey_ABC123.p8"
export APPLE_NOTARIZATION_KEY_ID="ABC123"
export APPLE_NOTARIZATION_ISSUER_ID="00000000-0000-0000-0000-000000000000"
```

`APPLE_NOTARIZATION_KEY_P8` may be either a `.p8` file path or the raw key
contents. If `BARNOWL_NOTARY_PROFILE` is already set, Barn Owl uses that profile
directly and does not create a replacement.

Then build, sign, notarize, staple, and zip. Prefer
`scripts/release-direct-download.sh` above for a release candidate; use this lower
level command only when you need to debug packaging:

```sh
BARNOWL_CODESIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
BARNOWL_NOTARIZE=1 \
BARNOWL_NOTARY_PROFILE="BarnOwlNotary" \
scripts/package-app.sh dist/BarnOwl.app.zip
```

For shared release work, prefer:

```sh
BARNOWL_CODESIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
scripts/release-direct-download.sh
```

That command accepts either `BARNOWL_NOTARY_PROFILE` or the
`APPLE_NOTARIZATION_*` variables above.

The script signs the staged app with hardened runtime and a timestamp, submits a
temporary zip to Apple notarization, staples the accepted ticket to the app, and
then writes the final `dist/BarnOwl.app.zip`.

`scripts/release-direct-download.sh` is stricter than `scripts/package-app.sh`:
it refuses dirty or commitless Git checkouts unless
`BARNOWL_ALLOW_DIRTY_RELEASE=1` is set. Prefer the stricter script for anything
you intend to share.

## Release Verification

Validate the full `dist/` package set before sharing it:

```sh
scripts/verify-dist.sh dist
```

`scripts/package-all.sh` runs this automatically after writing
`BarnOwl-release-manifest.json` and `SHA256SUMS`.

Validate a generated app package before sharing it:

```sh
scripts/verify-release.sh dist/BarnOwl.app.zip
```

`scripts/package-all.sh` runs this local/developer release check automatically.
The check verifies the archive shape, bundle identifier, code signature,
hardened runtime flag, required code-signing entitlements, bundled CLI, bundled
Codex skill resources, bundled Codex MCP app resources, and rejects bundled
local/private state such as databases, logs, raw audio, tokens, update manifests,
manual QA evidence, and `.env` files.

For a direct-download build, sign with Developer ID, notarize, staple the ticket,
then run:

```sh
scripts/verify-release.sh --direct-download dist/BarnOwl.app.zip
```

That stricter mode rejects ad-hoc signatures, requires a team identifier,
requires Developer ID Application signing, runs Gatekeeper assessment, and
validates the stapled notarization ticket.

For a full direct-download package-set gate, run:

```sh
scripts/verify-dist.sh --direct-download dist
```

When `BARNOWL_NOTARIZE=1` is set, `scripts/package-all.sh` runs this stricter
direct-download verification automatically after packaging.

### Stable Local Signing Without Developer ID

If a Developer ID certificate is unavailable, do not publish ad-hoc updates.
Ad-hoc signatures are tied to each build's code hash, which can make macOS treat
each update as a different app for Screen Recording/System Audio privacy grants.

For a single-user or small internal setup, use one long-lived local code-signing
certificate and keep using that same identity for every Barn Owl update:

```sh
scripts/create-local-signing-identity.sh
```

Then publish an internal GitHub update with that stable identity:

```sh
BARNOWL_CODESIGN_IDENTITY="Barn Owl Local Code Signing" \
BARNOWL_ALLOW_LOCAL_SIGNED_UPDATE=1 \
scripts/publish-git-update.sh
```

This is not notarization and it does not give Gatekeeper the same direct-download
trust as Developer ID. It is a pragmatic internal mode whose goal is to avoid
rotating Barn Owl's code identity on every update. Do not delete, recreate, or
rename the certificate unless you are prepared for macOS to ask for privacy
permissions again.

## Release Notes

Current packages are lightweight internal builds. They are ad-hoc signed,
checksum verified, and not notarized. Expect first-launch Gatekeeper friction on
other Macs. A DMG, Developer ID notarization, Sparkle feed, or stronger update
signature scheme can come later; none is required for the initial internal app
package download.
