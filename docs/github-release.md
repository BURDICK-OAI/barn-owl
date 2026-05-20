# Barn Owl GitHub Releases

GitHub Releases are the canonical distribution and update path for Barn Owl.
Local update manifests are for development and smoke testing only.

## Automated Internal Release Flow

Use the GitHub Actions workflow for the normal lightweight internal GitHub
Release path:

1. Commit and push the source change, build bump in
   `Apps/BarnOwlMac/Info.plist`, and release TLDR entry in
   `Apps/BarnOwlMac/BarnOwlChangelog.json` to `main`.
2. Open **Actions > Publish GitHub Release > Run workflow**.
3. Enter the build number already committed in `Apps/BarnOwlMac/Info.plist`.

The workflow runs on `main`, installs `ripgrep` and XcodeGen on its macOS runner,
verifies source, packages an internal ad-hoc signed build, creates the GitHub
Release, verifies that the published `BarnOwl.app.zip` hash matches the updater
manifest, and commits `Updates/BarnOwl` back to `main`.

This workflow is intentionally for the current internal ad-hoc release mode.
Ad-hoc signatures are allowed for the lightweight update path, but they do not
provide the continuity of a stable local signing certificate or a Developer ID
release. Use the local release flow below when the release must be signed with
the stable local Barn Owl certificate. Move the workflow to Developer ID signing
only after the certificate and notarization credentials are configured safely in
GitHub or on a controlled self-hosted Mac runner.

## Local Release Owner Flow

1. Confirm the source build is newer than the currently installed app:

   ```sh
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Apps/BarnOwlMac/Info.plist
   ```

2. Add or update the latest release entry in
   `Apps/BarnOwlMac/BarnOwlChangelog.json`. Packaging and GitHub update
   publishing require that changelog entry so Barn Owl Settings and the GitHub
   Release page describe what changed.

3. Build and verify the release artifacts. Developer ID/notarized releases are
   preferred, but internal updates may use a stable local signing identity when
   Developer ID is unavailable:

   ```sh
   BARNOWL_CODESIGN_IDENTITY="Barn Owl Local Code Signing" \
   scripts/package-all.sh
   ```

4. Generate the tracked GitHub update manifest:

   ```sh
   BARNOWL_CODESIGN_IDENTITY="Barn Owl Local Code Signing" \
   BARNOWL_ALLOW_LOCAL_SIGNED_UPDATE=1 \
   scripts/publish-git-update.sh
   ```

5. Commit and push the source and `Updates/BarnOwl` manifest changes:

   ```sh
   git add Apps/BarnOwlMac/Info.plist Updates/BarnOwl
   git commit -m "Publish Barn Owl 0.1.0 build 12"
   git push origin main
   ```

6. Create the GitHub Release and attach the app artifacts:

   ```sh
   release_notes="$(scripts/changelog-notes.sh 0.1.0 12 text)"
   gh release create v0.1.0-build.12 \
     dist/BarnOwl.app.zip \
     dist/BarnOwl-source-handoff.zip \
     dist/BarnOwl-release-manifest.json \
     dist/SHA256SUMS \
     --title "Barn Owl 0.1.0 build 12" \
     --notes "$release_notes"
   ```

Installed apps check this manifest by default:

```text
https://raw.githubusercontent.com/BURDICK-OAI/barn-owl/main/Updates/BarnOwl/BarnOwl-update-manifest.json
```

The tracked manifest points at the matching GitHub Release asset. Do not commit
binary app zips to Git history.

## Teammate Install Instructions

1. Open the latest Barn Owl GitHub Release:

   ```text
   https://github.com/BURDICK-OAI/barn-owl/releases/latest
   ```

2. Download `BarnOwl.app.zip`.

3. Unzip it and drag `Barn Owl.app` into `/Applications`.

4. Launch Barn Owl from `/Applications`.

5. If macOS blocks the first launch because the app is not notarized, open:

   ```text
   System Settings > Privacy & Security
   ```

   Then choose **Open Anyway** for Barn Owl. This is expected for the lightweight
   internal build.

6. In Barn Owl Settings, paste an OpenAI API key and choose **Save & Test Key**.

7. Grant microphone and screen/system-audio recording permissions when macOS asks.
   Barn Owl uses screen/system-audio permission only to capture meeting audio.

8. Start Barn Owl from the menu bar app, the main app window, or the bundled CLI:

   ```sh
   /Applications/Barn\ Owl.app/Contents/MacOS/barnowl status
   /Applications/Barn\ Owl.app/Contents/MacOS/barnowl start --title "Meeting"
   /Applications/Barn\ Owl.app/Contents/MacOS/barnowl stop
   ```

Future updates should appear through Barn Owl's **Update** button. Updates
replace the app bundle only; existing recordings, notes, preferences, and API key
configuration are preserved. If Developer ID is unavailable, keep using the same
local signing certificate for every release to avoid unnecessary macOS privacy
permission churn.
