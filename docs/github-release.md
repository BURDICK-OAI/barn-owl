# Barn Owl GitHub Releases

GitHub Releases are the canonical distribution and update path for Barn Owl.
Local update manifests are for development and smoke testing only.

## Release Owner Flow

1. Confirm the source build is newer than the currently installed app:

   ```sh
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Apps/BarnOwlMac/Info.plist
   ```

2. Build and verify the release artifacts:

   ```sh
   scripts/package-all.sh
   ```

3. Generate the tracked GitHub update manifest:

   ```sh
   scripts/publish-git-update.sh
   ```

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
configuration are preserved.
