# Barn Owl Updates

Barn Owl uses the same lightweight update shape locally and for the canonical
GitHub Release distribution path:

1. Build a versioned app bundle.
2. Package bundled assets into the app:
   - `Contents/MacOS/barnowl`
   - `Contents/Resources/CodexSkill/barnowl`
   - `Contents/Resources/CodexMCPApp`
3. Sign the app.
4. Zip the app.
5. Verify the zipped app with `scripts/verify-release.sh`.
6. Write a JSON update manifest to:
   `~/Library/Application Support/Barn Owl/update-manifest.json`
7. Barn Owl reads that manifest on launch, periodically while idle, and from the
   menu-bar or Settings **Update** button.
8. Installing the update replaces only the app bundle. Recordings, notes,
   preferences, the local meeting database, and Keychain API keys are preserved.

## Publish a Local Update

```zsh
scripts/update-local.sh
```

The script:

- builds Barn Owl into local DerivedData
- stamps the built app with a build number newer than `/Applications/Barn Owl.app`
- packages CLI, Codex skill, and Codex MCP app resources
- signs the app with hardened runtime enabled
- creates a zipped update archive under `~/Library/Application Support/Barn Owl/Updates`
- validates the archive shape, bundle identifier, privacy usage descriptions, bundled resources, code signature, and hardened runtime
- writes the local update manifest
- removes the generated debug `.app` bundle so Spotlight does not show duplicate Barn Owl apps

Then use:

```text
Barn Owl menu bar > Update
```

## GitHub Release Update Path

The app UI stays the same. Only the feed location changes:

- local development: JSON manifest on disk
- canonical internal distribution: HTTPS `BarnOwl-update-manifest.json` pointing at
  `BarnOwl.app.zip`, with a required SHA-256 checksum
- Ad-hoc sharing: send `BarnOwl.app.zip` and `BarnOwl-update-manifest.json`, or
  install the app zip manually

Remote JSON-manifest updates must use HTTPS, include a checksum in the manifest,
contain the Barn Owl bundle ID, and have a valid app code signature. Ad-hoc
signatures are allowed for this lightweight internal path; the checksum-bearing
manifest is the trust anchor. A future Sparkle path could add Sparkle signing and
installer flow without changing the user-facing Update button.

The menu bar and Settings should continue to expose one user action: **Update**.

The canonical release flow lives in [`docs/github-release.md`](github-release.md).

## Rollback Expectations

Barn Owl only installs updates whose manifest build is newer than the currently
installed app build. That prevents a bad or stale manifest from silently
downgrading users.

If an internal release must be rolled back:

1. Keep the previous known-good `BarnOwl.app.zip`,
   `BarnOwl-update-manifest.json`, and `SHA256SUMS` alongside every release.
2. For users who have not installed the bad build yet, restore the tracked
   update manifest to the previous release or pause publishing the newer one.
3. For users already on the bad build, either:
   - manually reinstall the prior `BarnOwl.app.zip`, which replaces only the app
     bundle and preserves recordings, notes, preferences, and API-key state, or
   - publish a new higher-build hotfix that restores the last known-good
     behavior and let the normal updater install that forward-moving rollback.

Do not claim that repointing the manifest to an older build will auto-downgrade
already-updated clients. It will not.
