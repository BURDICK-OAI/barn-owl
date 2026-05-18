#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-"$ROOT_DIR/DerivedData/Build/Products/Debug/BarnOwl.app"}"
UPDATE_DIR="${HOME}/Library/Application Support/Barn Owl/Updates"
MANIFEST_PATH="${HOME}/Library/Application Support/Barn Owl/update-manifest.json"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Barn Owl app not found: $APP_PATH" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
ARCHIVE_PATH="$UPDATE_DIR/BarnOwl-${VERSION}-${BUILD}.zip"
if RELEASE_NOTES="$("$ROOT_DIR/scripts/changelog-notes.sh" "$VERSION" "$BUILD" json 2>/dev/null)"; then
  RELEASE_NOTES_HISTORY="$("$ROOT_DIR/scripts/changelog-notes.sh" "$VERSION" "$BUILD" history-json)"
else
  RELEASE_NOTES='"Local Barn Owl development build."'
  RELEASE_NOTES_HISTORY="[]"
fi

/bin/mkdir -p "$UPDATE_DIR"
"$ROOT_DIR/scripts/package-barnowl-resources.sh" "$APP_PATH"
codesign_args=(--force --deep --options runtime --sign -)
if [[ -f "$ROOT_DIR/Apps/BarnOwlMac/BarnOwl.entitlements" ]]; then
  codesign_args+=(--entitlements "$ROOT_DIR/Apps/BarnOwlMac/BarnOwl.entitlements")
fi
/usr/bin/codesign "${codesign_args[@]}" "$APP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
"$ROOT_DIR/scripts/verify-release.sh" "$ARCHIVE_PATH" >&2
SHA256="$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" | /usr/bin/awk '{print $1}')"

/bin/cat > "$MANIFEST_PATH" <<JSON
{
  "version": "$VERSION",
  "build": "$BUILD",
  "archive_url": "$ARCHIVE_PATH",
  "sha256": "$SHA256",
  "notes": $RELEASE_NOTES,
  "release_notes": $RELEASE_NOTES_HISTORY
}
JSON

echo "Published Barn Owl $VERSION ($BUILD)"
echo "Archive: $ARCHIVE_PATH"
echo "Manifest: $MANIFEST_PATH"
