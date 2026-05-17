# Barn Owl GitHub Releases

GitHub Releases are the canonical distribution and update path for Barn Owl.
Local update manifests are for development and smoke testing only.

## Release Owner Flow

1. Confirm the source build is newer than the currently installed app:

   ```sh
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Apps/BarnOwlMac/Info.plist
   ```

2. Build and verify the release artifacts. Developer ID/notarized releases are
   preferred, but internal updates may use a stable local signing identity when
   Developer ID is unavailable. Barn Owl accepts either a pre-created
   `BARNOWL_NOTARY_PROFILE` or Apple notarization API key inputs via
   `APPLE_NOTARIZATION_KEY_P8`, `APPLE_NOTARIZATION_KEY_ID`, and
   `APPLE_NOTARIZATION_ISSUER_ID`:

   ```sh
   BARNOWL_CODESIGN_IDENTITY="Barn Owl Local Code Signing" \
   scripts/package-all.sh
   ```

   For the notarized direct-download path, use:

   ```sh
   BARNOWL_CODESIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
   scripts/release-direct-download.sh
   ```

3. Generate the tracked GitHub update manifest:

   ```sh
   BARNOWL_CODESIGN_IDENTITY="Barn Owl Local Code Signing" \
   BARNOWL_ALLOW_LOCAL_SIGNED_UPDATE=1 \
   scripts/publish-git-update.sh
   ```

   For a Developer ID/notarized release, use the Developer ID identity instead.
   `scripts/publish-git-update.sh` accepts the same notarization inputs described
   above and will package the update artifacts through the notarized path before
   writing the tracked manifest.

4. Commit and push the source and `Updates/BarnOwl` manifest changes:

   ```sh
   git add Apps/BarnOwlMac/Info.plist Updates/BarnOwl
   git commit -m "Publish Barn Owl 0.1.0 build 12"
   git push origin main
   ```

5. Create the GitHub Release and attach the app artifacts:

   ```sh
   gh release create v0.1.0-build.12 \
     dist/BarnOwl.app.zip \
     dist/BarnOwl-source-handoff.zip \
     dist/BarnOwl-release-manifest.json \
     dist/BarnOwl-update-manifest.json \
     dist/SHA256SUMS \
     --title "Barn Owl 0.1.0 build 12" \
     --notes "Internal Barn Owl release."
   ```

Installed apps check this manifest by default:

```text
https://raw.githubusercontent.com/BURDICK-OAI/barn-owl/main/Updates/BarnOwl/BarnOwl-update-manifest.json
```

The tracked manifest points at the matching GitHub Release asset. Do not commit
binary app zips to Git history.

## Rollback Plan

Keep the previous known-good release assets available after every publish:

- `BarnOwl.app.zip`
- `BarnOwl-source-handoff.zip`
- `BarnOwl-release-manifest.json`
- `BarnOwl-update-manifest.json`
- `SHA256SUMS`

Barn Owl only installs updates whose manifest build is newer than the app already
installed on the machine. That means restoring an older tracked manifest can
stop additional users from receiving a bad release, but it does not
auto-downgrade users who already installed it.

For an actual rollback:

1. If the bad release has not spread, restore the previous tracked manifest in
   `Updates/BarnOwl/` and commit that change.
2. If users already installed the bad build, either:
   - have them reinstall the previous `BarnOwl.app.zip` manually, which replaces
     only the app bundle and preserves local recordings, notes, preferences, and
     API-key configuration, or
   - publish a new higher-build rollback release built from the last known-good
     code and let the updater move users forward to that recovery build.

The second option is the better internal default when more than a couple of
people are affected. Fewer manual installs, less thrash.

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
