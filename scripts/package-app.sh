#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"
BUILD_DIR="${BUILD_DIR:-"$ROOT_DIR/.build/package"}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-"$BUILD_DIR/DerivedData"}"
OUTPUT_PATH="${1:-"$DIST_DIR/BarnOwl.app.zip"}"
BARNOWL_CODESIGN_IDENTITY="${BARNOWL_CODESIGN_IDENTITY:--}"
BARNOWL_NOTARIZE="${BARNOWL_NOTARIZE:-0}"
BARNOWL_NOTARY_PROFILE="${BARNOWL_NOTARY_PROFILE:-}"

if [[ "$BARNOWL_NOTARIZE" == "1" ]]; then
  if [[ "$BARNOWL_CODESIGN_IDENTITY" == "-" ]]; then
    echo "BARNOWL_NOTARIZE=1 requires BARNOWL_CODESIGN_IDENTITY to be a Developer ID Application identity." >&2
    exit 1
  fi
  if [[ -z "$BARNOWL_NOTARY_PROFILE" ]]; then
    echo "BARNOWL_NOTARIZE=1 requires BARNOWL_NOTARY_PROFILE to name an xcrun notarytool keychain profile." >&2
    exit 1
  fi
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required for notarization." >&2
    exit 1
  fi
fi

mkdir -p "$DIST_DIR"
mkdir -p "$BUILD_DIR"

BUILD_LOG="$BUILD_DIR/package-app.xcodebuild.log"

echo "Building BarnOwl ($CONFIGURATION)..." >&2
if ! xcodebuild build \
  -scheme BarnOwl \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_IDENTITY=- >"$BUILD_LOG" 2>&1; then
  echo "xcodebuild failed. Log: $BUILD_LOG" >&2
  tail -n 80 "$BUILD_LOG" >&2 || true
  exit 1
fi

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/BarnOwl.app"
STAGED_APP="$BUILD_DIR/BarnOwl.app"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 1
fi

rm -rf "$STAGED_APP"
ditto "$BUILT_APP" "$STAGED_APP"

while IFS= read -r -d '' executable; do
  if file "$executable" | grep -q 'Mach-O'; then
    strip -S "$executable" 2>/dev/null || true
  fi
done < <(find "$STAGED_APP" -type f -perm -111 -print0)

"$ROOT_DIR/scripts/package-barnowl-resources.sh" "$STAGED_APP" >&2

codesign_timestamp_args=()
if [[ "$BARNOWL_NOTARIZE" == "1" || "$BARNOWL_CODESIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
  codesign_timestamp_args+=(--timestamp)
else
  codesign_timestamp_args+=(--timestamp=none)
fi

# Re-sign nested frameworks before the outer app. Xcode builds the release app
# with local ad-hoc signatures first, so signed update packages need fresh nested
# signatures that match the final app signing mode.
while IFS= read -r -d '' framework; do
  codesign \
    --force \
    --options runtime \
    --sign "$BARNOWL_CODESIGN_IDENTITY" \
    "${codesign_timestamp_args[@]}" \
    "$framework" >&2
done < <(find "$STAGED_APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -type d -name '*.framework' -print0)

codesign_args=(--force --deep --options runtime --sign "$BARNOWL_CODESIGN_IDENTITY")
if [[ -f "$ROOT_DIR/Apps/BarnOwlMac/BarnOwl.entitlements" ]]; then
  codesign_args+=(--entitlements "$ROOT_DIR/Apps/BarnOwlMac/BarnOwl.entitlements")
fi
codesign_args+=("${codesign_timestamp_args[@]}")
codesign "${codesign_args[@]}" "$STAGED_APP" >&2

if [[ "$BARNOWL_NOTARIZE" == "1" ]]; then
  NOTARY_ZIP="$BUILD_DIR/BarnOwl-notary-submit.zip"
  rm -f "$NOTARY_ZIP"
  /usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$NOTARY_ZIP"
  /usr/bin/xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$BARNOWL_NOTARY_PROFILE" \
    --wait >&2
  /usr/bin/xcrun stapler staple "$STAGED_APP" >&2
fi

rm -f "$OUTPUT_PATH"
/usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$OUTPUT_PATH"

if [[ "${BARNOWL_KEEP_PACKAGE_APP:-0}" != "1" ]]; then
  rm -rf "$STAGED_APP" "$BUILT_APP"
fi

echo "$OUTPUT_PATH"
